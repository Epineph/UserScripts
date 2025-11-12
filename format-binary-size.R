#!/usr/bin/env Rscript
# Goal:
#   Accept any combination of values in B/KiB/MiB/GiB (optionally with KB/MB/GB aliases
#   mapped to binary units), sum them in bytes, and format the total using:
#     - "remainder style": Largest unit + one remainder tier (MiB→KiB or bytes; GiB→MiB/KiB/bytes).
#     - "full expansion":  GiB + MiB + KiB + bytes (non-zero parts only).
#
# Design:
#   1) Define exact IEC multipliers.
#   2) Normalize unit tokens (aliases → canonical: B, KiB, MiB, GiB).
#   3) Parse free-form tokens like "1.5 GiB", "2048B", "512 KiB".
#   4) Accept both string tokens and named numeric inputs (bytes=, kib=, ...).
#   5) Floor fractional bytes (deterministic, conservative).
#
# Note: This is a pedagogical function intended for inclusion in larger scripts.

format_binary_size_r <- local({
  IEC <- c(B = 1L, KiB = bitwShiftL(1L, 10L), MiB = bitwShiftL(1L, 20L), GiB = bitwShiftL(1L, 30L))

  # Map many spellings to canonical IEC units (case-insensitive)
  normalize_unit <- function(u) {
    key <- tolower(trimws(u))
    if (key %in% c("b", "byte", "bytes")) return("B")
    if (key %in% c("kib", "kb", "kibibyte", "kibibytes", "k")) return("KiB")
    if (key %in% c("mib", "mb", "mebibyte", "mebibytes", "m")) return("MiB")
    if (key %in% c("gib", "gb", "gibibyte", "gibibytes", "g")) return("GiB")
    stop(sprintf("Unknown unit: %s. Allowed: B/KiB/MiB/GiB (KB/MB/GB map to binary).", u), call. = FALSE)
  }

  # Convert value + unit to integer bytes (floored)
  to_bytes <- function(value, unit) {
    if (any(value < 0, na.rm = TRUE)) stop("Sizes must be non-negative.", call. = FALSE)
    mult <- IEC[[ normalize_unit(unit) ]]
    # Floor to whole bytes to avoid rounding up
    as.integer(floor(as.numeric(value) * mult))
  }

  # Parse one textual token like "1.5 GiB" or "2048B"
  parse_token <- function(token) {
    token <- trimws(token)
    m <- regexec("^([+-]?[0-9]+(?:\\.[0-9]+)?)\\s*([A-Za-z]+)$", token)
    mm <- regmatches(token, m)[[1]]
    if (length(mm) != 3L) stop(sprintf("Could not parse token %s (expected e.g. '512B', '2 KiB', '1.5GiB').", token), call. = FALSE)
    val <- as.numeric(mm[2L]); unit <- mm[3L]
    to_bytes(val, unit)
  }

  # The returned function (closure captures IEC/normalize/parse helpers)
  function(...,
           bytes = 0, b = 0,
           kib = 0, kb = 0,
           mib = 0, mb = 0,
           gib = 0, gb = 0,
           full = FALSE) {
    dots <- list(...)
    total <- 0L

    # 1) Positional inputs: allow numbers (assumed bytes) or character tokens (e.g., "2 MiB")
    if (length(dots)) {
      for (x in dots) {
        if (is.character(x)) {
          total <- total + sum(vapply(x, parse_token, integer(1L)))
        } else if (is.numeric(x)) {
          total <- total + to_bytes(x, "B")
        } else {
          stop(sprintf("Unsupported input type in ...: %s", class(x)[1L]), call. = FALSE)
        }
      }
    }

    # 2) Named components (aliases map to binary)
    total <- total +
      to_bytes(bytes, "B") + to_bytes(b, "B") +
      to_bytes(kib, "KiB") + to_bytes(kb, "KiB") +
      to_bytes(mib, "MiB") + to_bytes(mb, "MiB") +
      to_bytes(gib, "GiB") + to_bytes(gb, "GiB")

    B   <- IEC[["B"]]; KiB <- IEC[["KiB"]]; MiB <- IEC[["MiB"]]; GiB <- IEC[["GiB"]]

    # -------- full expansion (optional) --------------------------------------
    if (isTRUE(full)) {
      g <- total %/% GiB; r <- total %% GiB
      m <- r %/% MiB;   r <- r %% MiB
      k <- r %/% KiB;   r <- r %% KiB
      parts <- c(if (g) sprintf("%d GiB", g),
                 if (m) sprintf("%d MiB", m),
                 if (k) sprintf("%d KiB", k),
                 if (r) sprintf("%d bytes", r))
      if (!length(parts)) parts <- "0 bytes"
      return(sprintf("%s (= %d bytes)", paste(parts, collapse = " "), total))
    }

    # -------- remainder-style formatting -------------------------------------
    if (total < KiB) {
      return(sprintf("%d bytes (= %d bytes)", total, total))
    }
    if (total < MiB) {
      k <- total %/% KiB; r <- total %% KiB
      s <- sprintf("%d KiB", k)
      if (r) s <- sprintf("%s remainder %d bytes", s, r)
      return(sprintf("%s (= %d bytes)", s, total))
    }
    if (total < GiB) {
      m <- total %/% MiB; r <- total %% MiB
      s <- sprintf("%d MiB", m)
      if (r) {
        if (r >= KiB) s <- sprintf("%s remainder %d KiB", s, r %/% KiB)
        else          s <- sprintf("%s remainder %d bytes", s, r)
      }
      return(sprintf("%s (= %d bytes)", s, total))
    }
    # total >= GiB
    g <- total %/% GiB; r <- total %% GiB
    s <- sprintf("%d GiB", g)
    if (r) {
      if (r >= MiB)      s <- sprintf("%s remainder %d MiB", s, r %/% MiB)
      else if (r >= KiB) s <- sprintf("%s remainder %d KiB", s, r %/% KiB)
      else               s <- sprintf("%s remainder %d bytes", s, r)
    }
    sprintf("%s (= %d bytes)", s, total)
  }
}

# ---------------------------- Worked examples --------------------------------
# Remainder-style:
# format_binary_size_r("1536B")
# [1] "1 KiB remainder 512 bytes (= 1536 bytes)"
#
# format_binary_size_r(gib = 1, mib = 512, kib = 600)
# [1] "1 GiB remainder 512 MiB (= 1611661312 bytes)"
#
# Full expansion:
# format_binary_size_r("1 GiB", "512 MiB", "600 KiB", full = TRUE)
# [1] "1 GiB 512 MiB 600 KiB (= 1611661312 bytes)"

