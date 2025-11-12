# ---------- Utilities ----------

#' Is package installed (by name)?
is_installed <- function(pkg) {
  # Fast membership check using installed.packages cache:
  pkg %in% .installed_cache()
}

.installed_cache <- local({
  cache <- NULL
  function(refresh = FALSE) {
    if (is.null(cache) || isTRUE(refresh)) {
      cache <<- rownames(installed.packages(noCache = TRUE))
    }
    cache
  }
})

#' Run expression quietly, discarding stdout + stderr (to /dev/null or NUL)
run_quietly <- function(expr) {
  nullfile <- if (.Platform$OS.type == "windows") "NUL" else "/dev/null"
  zz_out <- file(nullfile, open = "wt")
  zz_msg <- file(nullfile, open = "wt")
  sink(zz_out)
  sink(zz_msg, type = "message")
  on.exit(
    {
      try(sink(), silent = TRUE)
      try(sink(type = "message"), silent = TRUE)
      close(zz_out)
      close(zz_msg)
    },
    add = TRUE
  )
  force(expr)
}

#' Safe require/library
safe_library <- function(pkg) {
  ok <- FALSE
  err <- NULL
  res <- tryCatch(
    {
      suppressPackageStartupMessages(suppressWarnings(
        library(pkg, character.only = TRUE, quietly = TRUE)
      ))
      TRUE
    },
    error = function(e) {
      err <<- e
      FALSE
    }
  )
  list(ok = res, error = err)
}

#' Ensure we have a CRAN repo set
ensure_cran_repos <- function() {
  repos <- getOption("repos")
  if (is.null(repos) || length(repos) == 0L || isTRUE(repos["CRAN"] == "@CRAN@")) {
    options(repos = c(CRAN = "https://cloud.r-project.org"))
  }
}

# ---------- Spec parsing ----------

# Normalize a single character spec into a list {source, pkg, repo, ref}
# Rules:
#   - "cran:pkg" or plain "pkg" => source="cran", pkg="pkg"
#   - "bioc:Pkg"                => source="bioc", pkg="Pkg"
#   - "github:owner/repo[@ref]" / "gh:owner/repo[@ref]" / "owner/repo[@ref]" => source="github"
parse_one_spec <- function(x) {
  stopifnot(is.character(x), length(x) == 1L)
  x <- trimws(x)

  if (grepl("^pak:", x, ignore.case = TRUE)) {
    inner <- sub("^pak:", "", x, ignore.case = TRUE)
    sp <- parse_one_spec(inner)
    sp$via <- "pak"
    return(sp)
  }
  # pak-style explicit forms:
  #   github::owner/repo[@ref]
  #   bioc::Package
  if (grepl("^github::", x, ignore.case = TRUE)) {
    repo_spec <- sub("^github::", "", x, ignore.case = TRUE)
    parts <- strsplit(repo_spec, "@", fixed = TRUE)[[1]]
    repo <- parts[1]
    ref <- if (length(parts) > 1) parts[2] else NULL
    pkg <- basename(repo)
    return(list(source = "github", pkg = pkg, repo = repo, ref = ref, via = "pak"))
  }

  if (grepl("^bioc::", x, ignore.case = TRUE)) {
    pkg <- sub("^bioc::", "", x, ignore.case = TRUE)
    return(list(source = "bioc", pkg = pkg, via = "pak"))
  }

  if (grepl("^cran:", x, ignore.case = TRUE)) {
    pkg <- sub("^cran:", "", x, ignore.case = TRUE)
    return(list(source = "cran", pkg = pkg))
  }

  if (grepl("^bioc:", x, ignore.case = TRUE)) {
    pkg <- sub("^bioc:", "", x, ignore.case = TRUE)
    return(list(source = "bioc", pkg = pkg))
  }

  if (grepl("^(github|gh):", x, ignore.case = TRUE)) {
    repo <- sub("^(github|gh):", "", x, ignore.case = TRUE)
    parts <- strsplit(repo, "@", fixed = TRUE)[[1]]
    repo <- parts[1]
    ref <- if (length(parts) > 1) parts[2] else NULL
    pkg <- basename(repo)
    return(list(source = "github", pkg = pkg, repo = repo, ref = ref))
  }

  # Heuristic: owner/repo => GitHub
  if (grepl("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(@[A-Za-z0-9_.-]+)?$", x)) {
    parts <- strsplit(x, "@", fixed = TRUE)[[1]]
    repo <- parts[1]
    ref <- if (length(parts) > 1) parts[2] else NULL
    pkg <- basename(repo)
    return(list(source = "github", pkg = pkg, repo = repo, ref = ref))
  }

  # Fallback: plain CRAN name
  list(source = "cran", pkg = x)
}

# Vectorized parse
parse_specs <- function(pkgs) {
  if (!length(pkgs)) {
    return(list())
  }
  lapply(pkgs, parse_one_spec)
}

# ---------- Installers ----------

install_cran <- function(pkg, dependencies, quiet) {
  ensure_cran_repos()
  nullrun <- if (quiet) run_quietly else identity
  nullrun(install.packages(pkg,
    dependencies = dependencies,
    quiet = quiet,
    Ncpus = max(1L, getOption("Ncpus", 1L))
  ))
}

ensure_installer <- function(which = c("remotes", "devtools"), quiet = TRUE) {
  which <- match.arg(which)
  if (!is_installed(which)) {
    install_cran(which, dependencies = TRUE, quiet = quiet)
    .installed_cache(refresh = TRUE)
  }
}

install_github_remotes <- function(repo, dependencies, ref = NULL, quiet = TRUE) {
  ensure_installer("remotes", quiet = quiet)
  args <- list(repo = repo, dependencies = dependencies, upgrade = "never", quiet = quiet)
  if (!is.null(ref)) args$ref <- ref
  f <- get("install_github", envir = asNamespace("remotes"))
  (if (quiet) run_quietly else identity)(do.call(f, args))
}

install_github_devtools <- function(repo, dependencies, ref = NULL, quiet = TRUE) {
  ensure_installer("devtools", quiet = quiet)
  args <- list(repo = repo, dependencies = dependencies, upgrade = "never", quiet = quiet)
  if (!is.null(ref)) args$ref <- ref
  f <- get("install_github", envir = asNamespace("devtools"))
  (if (quiet) run_quietly else identity)(do.call(f, args))
}

install_bioc <- function(pkg, dependencies, quiet = TRUE) {
  # Bioconductor optional: only if user requests 'bioc:' prefix.
  if (!is_installed("BiocManager")) {
    install_cran("BiocManager", dependencies = TRUE, quiet = quiet)
    .installed_cache(refresh = TRUE)
  }
  f <- get("install", envir = asNamespace("BiocManager"))
  (if (quiet) run_quietly else identity)(f(pkg, dependencies = dependencies, ask = FALSE, update = FALSE))
}

# ---- pak integration ---------------------------------------------------------

# Ensure 'pak' is available; try CRAN first, then GitHub fallback.
ensure_pak <- function(quiet = TRUE) {
  if (!is_installed("pak")) {
    # Attempt CRAN first
    try(install_cran("pak", dependencies = TRUE, quiet = quiet), silent = TRUE)
    .installed_cache(refresh = TRUE)
    if (!is_installed("pak")) {
      # Fallback to GitHub (bootstrap via remotes)
      ensure_installer("remotes", quiet = quiet)
      (if (quiet) run_quietly else identity)(
        remotes::install_github("r-lib/pak", upgrade = "never", quiet = quiet, dependencies = TRUE)
      )
      .installed_cache(refresh = TRUE)
    }
  }
}

# Generic installer via pak::pkg_install(), translating our spec to pak syntax.
install_via_pak <- function(sp, dependencies, quiet = TRUE) {
  ensure_pak(quiet = quiet)
  spec <- switch(sp$source,
    cran   = sp$pkg, # e.g., "arrow"
    github = paste0("github::", sp$repo, if (!is.null(sp$ref)) paste0("@", sp$ref) else ""),
    bioc   = paste0("bioc::", sp$pkg),
    stop("pak installer does not support source: ", sp$source)
  )
  f <- get("pkg_install", envir = asNamespace("pak"))
  (if (quiet) run_quietly else identity)(
    f(spec, dependencies = dependencies, upgrade = FALSE, ask = FALSE)
  )
}

# ---------- Core API ----------

#' smart_install
#'
#' @param pkgs character vector of package specs (see header)
#' @param dependencies TRUE (default), FALSE, NA, or character vector like c("Depends","Suggests")
#' @param load logical: library() attach after installation (default TRUE)
#' @param install_github_via "remotes" (default) or "devtools"
#' @param quiet logical: suppress output where possible (default TRUE)
#' @param prefer_github_if_both logical: if TRUE and both CRAN and GitHub versions are installed/available,
#'        prefer GitHub install. Default FALSE (CRAN stability first).
#' @param use_pak logical: if TRUE, route all installs via pak::pkg_install(). Defaults to FALSE.
#'        Per-package override via specs "pak:<spec>", "github::<owner>/<repo>[@ref]", "bioc::Pkg".
#' @param progress logical: print lightweight progress markers. Default interactive().
#' @return list with components: installed_new, already_installed, loaded, failed_install, failed_load, not_found
smart_install <- function(pkgs,
                          dependencies = TRUE,
                          load = TRUE,
                          install_github_via = c("remotes", "devtools"),
                          quiet = TRUE,
                          prefer_github_if_both = FALSE,
                          use_pak = FALSE,
                          progress = interactive()) {
  stopifnot(is.character(pkgs) || is.list(pkgs))
  specs <- if (is.character(pkgs)) parse_specs(pkgs) else lapply(pkgs, parse_one_spec)

  install_github_via <- match.arg(install_github_via)

  installed_new     <- character()
  already_installed <- character()
  loaded_ok         <- character()
  failed_install    <- character()
  failed_load       <- character()
  not_found         <- character()

  # Processing
  for (sp in specs) {
    src <- sp$source
    pkg <- sp$pkg

    # Backend selection and progress marker
    use_pak_here <- isTRUE(use_pak) || identical(sp$via, "pak")
    backend_label <- if (use_pak_here) {
      "pak"
    } else if (src == "github") {
      install_github_via
    } else if (src == "bioc") {
      "BiocManager"
    } else {
      "base"
    }
    if (isTRUE(progress)) {
      message(sprintf("→ %s: installing from %s via %s ...", pkg, src, backend_label))
    }

    # Decide if we should install
    do_install <- !is_installed(pkg) || (src == "github" && isTRUE(prefer_github_if_both))

    if (isTRUE(do_install)) {
      ok <- TRUE
      tryCatch({
        if (use_pak_here) {
          install_via_pak(sp, dependencies = dependencies, quiet = quiet)
        } else if (src == "cran") {
          install_cran(pkg, dependencies = dependencies, quiet = quiet)
        } else if (src == "github") {
          if (identical(install_github_via, "remotes")) {
            install_github_remotes(sp$repo, dependencies = dependencies, ref = sp$ref, quiet = quiet)
          } else {
            install_github_devtools(sp$repo, dependencies = dependencies, ref = sp$ref, quiet = quiet)
          }
        } else if (src == "bioc") {
          install_bioc(pkg, dependencies = dependencies, quiet = quiet)
        } else {
          stop("Unknown source: ", src)
        }
      }, error = function(e) {
        ok <<- FALSE
      })

      # Refresh installed cache after install attempt
      .installed_cache(refresh = TRUE)

      if (ok && is_installed(pkg)) {
        installed_new <- c(installed_new, pkg)
      } else {
        failed_install <- c(failed_install, pkg)
        if (!is_installed(pkg)) not_found <- c(not_found, pkg)
        next
      }
    } else {
      already_installed <- c(already_installed, pkg)
    }

    # Load if requested
    if (isTRUE(load)) {
      res <- safe_library(pkg)
      if (isTRUE(res$ok)) loaded_ok <- c(loaded_ok, pkg) else failed_load <- c(failed_load, pkg)
    }
  }

  # Deduplicate & sort for readability
  uniq_sort <- function(x) sort(unique(x))
  result <- list(
    installed_new     = uniq_sort(installed_new),
    already_installed = uniq_sort(already_installed),
    loaded            = uniq_sort(loaded_ok),
    failed_install    = uniq_sort(failed_install),
    failed_load       = uniq_sort(failed_load),
    not_found         = uniq_sort(setdiff(not_found, loaded_ok))
  )

  # Human-readable summary
  summarize <- function(lbl, xs) {
    if (!length(xs)) sprintf("%s: none", lbl) else sprintf("%s (%d): %s", lbl, length(xs), paste(xs, collapse = ", "))
  }
  message(summarize("Installed (new)",    result$installed_new))
  message(summarize("Already installed",  result$already_installed))
  message(summarize("Loaded",             result$loaded))
  if (length(result$failed_install)) message(summarize("Failed to install", result$failed_install))
  if (length(result$failed_load))    message(summarize("Failed to load",    result$failed_load))
  if (length(result$not_found))      message(summarize("Not found (typo?)", result$not_found))

  invisible(result)
}

