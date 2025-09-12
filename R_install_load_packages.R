#!/usr/bin/env Rscript
##
## smart-install.R — Deterministic package bootstrapper with CRAN/GitHub/Bioc
##
## - CRAN by default using install.packages()
## - GitHub via remotes::install_github() (default) or devtools::install_github()
## - Optional Bioconductor via BiocManager::install()
## - Dependencies: TRUE by default (supports FALSE, NA, or character vector like c("Depends","Suggests"))
## - Loads packages after install; never halts on errors; prints a summary of failures/typos
##
## Design goals:
##   1) Idempotent: only installs when necessary
##   2) Predictable: explicit source parsing; no implicit magic beyond well-documented rules
##   3) Quiet: redirects non-critical noise, but surfaces actionable failures
##   4) Composable: returns a structured list for programmatic use
##
## Accepted package spec formats (character vector):
##   - "ggplot2"                    -> CRAN
##   - "cran:ggplot2"               -> CRAN
##   - "github:r-lib/usethis"       -> GitHub (branch/tag/sha allowed: r-lib/usethis@v3.0.0)
##   - "gh:tidyverse/dplyr"         -> GitHub
##   - "r-lib/usethis"              -> GitHub (heuristic: owner/repo with slash and no "cran:" prefix)
##   - "bioc:DESeq2"                -> Bioconductor (optional)
##
## Examples (function):
##   smart_install(c("data.table", "gh:r-lib/usethis", "r-lib/pkgcache", "bioc:BiocGenerics"),
##                 dependencies = TRUE, install_github_via = "remotes")
##
## Examples (CLI):
##   Rscript smart-install.R --packages="data.table,gh:r-lib/usethis,r-lib/pkgcache" --dependencies=TRUE
##   Rscript smart-install.R --packages-file=/path/pkgs.txt --deps="Suggests"
##   Rscript smart-install.R --packages="bioc:DESeq2,cran:ggplot2" --github=devtools
##
## Help:
##   Rscript smart-install.R --help
##

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
  on.exit({
    try(sink(), silent = TRUE)
    try(sink(type = "message"), silent = TRUE)
    close(zz_out); close(zz_msg)
  }, add = TRUE)
  force(expr)
}

#' Safe require/library
safe_library <- function(pkg) {
  ok <- FALSE
  err <- NULL
  res <- tryCatch({
    suppressPackageStartupMessages(suppressWarnings(
      library(pkg, character.only = TRUE, quietly = TRUE)
    ))
    TRUE
  }, error = function(e) { err <<- e; FALSE })
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
    ref  <- if (length(parts) > 1) parts[2] else NULL
    pkg  <- basename(repo)
    return(list(source = "github", pkg = pkg, repo = repo, ref = ref))
  }

  # Heuristic: owner/repo => GitHub
  if (grepl("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(@[A-Za-z0-9_.-]+)?$", x)) {
    parts <- strsplit(x, "@", fixed = TRUE)[[1]]
    repo <- parts[1]
    ref  <- if (length(parts) > 1) parts[2] else NULL
    pkg  <- basename(repo)
    return(list(source = "github", pkg = pkg, repo = repo, ref = ref))
  }

  # Fallback: plain CRAN name
  list(source = "cran", pkg = x)
}

# Vectorized parse
parse_specs <- function(pkgs) {
  if (!length(pkgs)) return(list())
  lapply(pkgs, parse_one_spec)
}

# ---------- Installers ----------

install_cran <- function(pkg, dependencies, quiet) {
  ensure_cran_repos()
  nullrun <- if (quiet) run_quietly else identity
  nullrun(install.packages(pkg,
                           dependencies = dependencies,
                           quiet = quiet,
                           Ncpus = max(1L, getOption("Ncpus", 1L))))
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
#' @return list with components: installed_new, already_installed, loaded, failed_install, failed_load, not_found
smart_install <- function(pkgs,
                          dependencies = TRUE,
                          load = TRUE,
                          install_github_via = c("remotes", "devtools"),
                          quiet = TRUE,
                          prefer_github_if_both = FALSE) {
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

    # Decide if already installed
    if (is_installed(pkg)) {
      already_installed <- c(already_installed, pkg)
      # Optionally re-install from GitHub if requested preference
      do_install <- FALSE
      if (src == "github" && isTRUE(prefer_github_if_both)) do_install <- TRUE
    } else {
      do_install <- TRUE
    }

    if (isTRUE(do_install)) {
      ok <- TRUE
      err <- NULL
      tryCatch({
        if (src == "cran") {
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
      }, error = function(e) { ok <<- FALSE; err <<- e })

      # Refresh installed cache after install attempt
      .installed_cache(refresh = TRUE)

      if (ok && is_installed(pkg)) {
        installed_new <- c(installed_new, pkg)
      } else {
        failed_install <- c(failed_install, pkg)
        # If the package truly isn't installed, classify as not_found (likely typo)
        if (!is_installed(pkg)) not_found <- c(not_found, pkg)
        # Continue to next package; loading makes no sense here
        next
      }
    }

    # Load if requested
    if (isTRUE(load)) {
      res <- safe_library(pkg)
      if (isTRUE(res$ok)) {
        loaded_ok <- c(loaded_ok, pkg)
      } else {
        failed_load <- c(failed_load, pkg)
      }
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

# ---------- CLI Wrapper (optional) ----------

print_help <- function() {
  cat <<'EOF'
smart-install.R — install and load R packages from CRAN/GitHub/Bioc

USAGE:
  Rscript smart-install.R [--packages="<spec1,spec2,...>"] [--packages-file=/path/list.txt]
                          [--dependencies=TRUE|FALSE|NA|"Suggests"|...]
                          [--github=remotes|devtools] [--no-load] [--verbose]

PACKAGE SPEC FORMATS:
  - Plain CRAN:         ggplot2
  - Explicit CRAN:      cran:ggplot2
  - GitHub (prefix):    github:r-lib/usethis      or gh:r-lib/usethis
  - GitHub (heuristic): r-lib/usethis             (owner/repo)
  - GitHub with ref:    r-lib/usethis@v3.0.0
  - Bioconductor:       bioc:DESeq2               (optional)

OPTIONS:
  --packages           Comma-separated package specs (see above).
  --packages-file      Path to a text file with one spec per line (comments '#' allowed).
  --dependencies       TRUE (default), FALSE, NA, or character vector as a single string,
                       e.g., "Depends,Suggests" (quotes required).
  --github             Installer for GitHub: 'remotes' (default) or 'devtools'.
  --no-load            Do not library() attach after installation.
  --verbose            Show installer output (by default, most noise is suppressed).
  --help, -h           Show this help.

EXAMPLES:
  Rscript smart-install.R --packages="data.table,gh:r-lib/usethis,r-lib/pkgcache"
  Rscript smart-install.R --packages-file=pkgs.txt --dependencies="Depends,Suggests"
  Rscript smart-install.R --packages="bioc:DESeq2,cran:ggplot2" --github=devtools

EXIT:
  Always exits 0. Inspect the printed summary for failures.

EOF
}

# Basic CLI only when executed via Rscript
if (!interactive()) {
  args <- commandArgs(trailingOnly = TRUE)
  if (any(args %in% c("--help", "-h"))) {
    print_help()
    quit(status = 0)
  }

  # Parse simple flags
  get_arg <- function(flag, default = NULL, has_value = TRUE) {
    if (has_value) {
      ix <- grep(paste0("^", flag, "="), args)
      if (length(ix)) sub(paste0("^", flag, "="), "", args[ix[1]]) else default
    } else {
      any(args == flag)
    }
  }

  pkgs_str  <- get_arg("--packages", default = "")
  pkgs_file <- get_arg("--packages-file", default = "")
  deps_str  <- get_arg("--dependencies", default = "TRUE")
  gh_tool   <- get_arg("--github", default = "remotes")
  no_load   <- get_arg("--no-load", default = FALSE, has_value = FALSE)
  verbose   <- get_arg("--verbose",  default = FALSE, has_value = FALSE)

  # Build package vector
  pkgs <- character()
  if (nzchar(pkgs_str)) {
    # split on commas, trimming whitespace
    pkgs <- c(pkgs, unlist(strsplit(pkgs_str, ",", fixed = TRUE)))
  }
  if (nzchar(pkgs_file)) {
    if (!file.exists(pkgs_file)) stop("packages-file not found: ", pkgs_file)
    lines <- readLines(pkgs_file, warn = FALSE)
    lines <- trimws(lines)
    lines <- lines[!grepl("^\\s*#", lines)]   # drop comments
    lines <- lines[nzchar(lines)]             # drop empty
    pkgs <- c(pkgs, lines)
  }
  pkgs <- trimws(pkgs)
  pkgs <- pkgs[nzchar(pkgs)]

  # Dependencies parsing
  dependencies <- switch(tolower(deps_str),
                         "true"  = TRUE,
                         "false" = FALSE,
                         "na"    = NA,
                         { # allow character vector in quotes like "Depends,Suggests"
                           # split on commas
                           deps <- trimws(unlist(strsplit(deps_str, ",", fixed = TRUE)))
                           if (length(deps)) deps else TRUE
                         })

  if (!length(pkgs)) {
    message("No packages specified. Use --help for usage.")
    quit(status = 0)
  }

  # Invoke core
  smart_install(pkgs,
                dependencies = dependencies,
                load = !isTRUE(no_load),
                install_github_via = gh_tool,
                quiet = !isTRUE(verbose))
}

