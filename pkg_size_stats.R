#!/usr/bin/env Rscript

## ---------------------------------------------------------------------##
##  pkg_size_stats.R                                                    ##
##                                                                      ##
##  Analyse Arch package size report CSV from sort-pkg-by-size-report. ##
##                                                                      ##
##  Inputs                                                              ##
##  ------                                                              ##
##  1. Path to pkg_by_size_report.csv                                   ##
##  2. Optional: output directory (default = directory of the CSV)      ##
##                                                                      ##
##  Outputs                                                             ##
##  -------                                                             ##
##  - pkg_size_summary.txt                                              ##
##  - pkg_size_outliers_high.csv                                        ##
##  - pkg_size_outliers_low.csv                                         ##
##  - pkg_size_hist_linear.png                                          ##
##  - pkg_size_hist_log10.png                                           ##
## ---------------------------------------------------------------------##

suppressWarnings(suppressMessages({
  ## base R only; no extra packages needed
}))

## ------------------------ argument parsing ---------------------------##

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 1L) {
  cat(
    "Usage:\n",
    "  pkg_size_stats.R /path/to/pkg_by_size_report.csv [outdir]\n\n",
    "Example:\n",
    "  pkg_size_stats.R ",
    "~/exported_csv_logs/sort_pkg_by_size/20251206_084151/pkg_by_size_report.csv\n",
    sep = ""
  )
  quit(status = 1L)
}

csv_path <- normalizePath(args[1L])
outdir   <- if (length(args) >= 2L) normalizePath(args[2L]) else dirname(csv_path)

if (!file.exists(csv_path)) {
  stop("Input CSV does not exist: ", csv_path, call. = FALSE)
}

if (!dir.exists(outdir)) {
  dir.create(outdir, recursive = TRUE, showWarnings = FALSE)
}

## ------------------------ data import --------------------------------##

df <- read.csv(csv_path, stringsAsFactors = FALSE)

required_cols <- c("package", "size_kib")
missing_cols  <- setdiff(required_cols, names(df))
if (length(missing_cols) > 0L) {
  stop("CSV is missing required columns: ",
       paste(missing_cols, collapse = ", "),
       call. = FALSE)
}

df$size_kib <- as.numeric(df$size_kib)
if (anyNA(df$size_kib)) {
  warning("Some size_kib values could not be parsed as numeric.")
}

## KiB -> MiB / GiB
df$size_mib <- df$size_kib / 1024
df$size_gib <- df$size_mib / 1024

## ------------------------ summary statistics -------------------------##

n_pkgs      <- nrow(df)
total_kib   <- sum(df$size_kib, na.rm = TRUE)
total_gib   <- total_kib / (1024 ^ 2)

mean_mib    <- mean(df$size_mib, na.rm = TRUE)
median_mib  <- median(df$size_mib, na.rm = TRUE)
sd_mib      <- sd(df$size_mib, na.rm = TRUE)

quantiles   <- quantile(
  df$size_mib,
  probs = c(0.25, 0.50, 0.75, 0.90, 0.95, 0.99),
  na.rm = TRUE
)

## z-scores: z_i = (x_i - mean) / sd
if (is.na(sd_mib) || sd_mib == 0) {
  df$z_score <- NA_real_
} else {
  df$z_score <- (df$size_mib - mean_mib) / sd_mib
}

## Outlier thresholds (symmetric)
z_thr_high <- 2.0
z_thr_low  <- -2.0

high_outliers <- df[!is.na(df$z_score) & df$z_score >= z_thr_high, ]
low_outliers  <- df[!is.na(df$z_score) & df$z_score <= z_thr_low, ]

## Order outliers by size descending for readability
high_outliers <- high_outliers[order(high_outliers$size_mib, decreasing = TRUE), ]
low_outliers  <- low_outliers[order(low_outliers$size_mib, decreasing = FALSE), ]

## ------------------------ write summary text -------------------------##

summary_path <- file.path(outdir, "pkg_size_summary.txt")
con <- file(summary_path, open = "wt")

write_line <- function(...) {
  cat(paste0(..., "\n"), file = con)
}

write_line("Package size statistics")
write_line("-----------------------")
write_line("Source CSV: ", csv_path)
write_line("Output dir: ", outdir)
write_line("")
write_line(sprintf("Number of packages      : %d", n_pkgs))
write_line(sprintf("Total size              : %.2f GiB", total_gib))
write_line(sprintf("Mean size (MiB)         : %.2f",   mean_mib))
write_line(sprintf("Median size (MiB)       : %.2f",   median_mib))
write_line(sprintf("Std. dev. size (MiB)    : %.2f",   sd_mib))
write_line("")
write_line("Quantiles of size (MiB):")
for (p in names(quantiles)) {
  write_line(sprintf("  %s : %.2f", p, quantiles[[p]]))
}
write_line("")
write_line("Outlier definition:")
write_line(sprintf("  z-score z_i = (x_i - mean) / sd"))
write_line(sprintf("  High outliers : z_i >= %.2f", z_thr_high))
write_line(sprintf("  Low  outliers : z_i <= %.2f", z_thr_low))
write_line("")
write_line(sprintf("High outliers count (z >= %.2f): %d",
                   z_thr_high, nrow(high_outliers)))
write_line(sprintf("Low  outliers count (z <= %.2f): %d",
                   z_thr_low,  nrow(low_outliers)))

if (nrow(high_outliers) > 0L) {
  write_line("")
  write_line("Top 10 largest high outliers (MiB):")
  top_n <- min(10L, nrow(high_outliers))
  for (i in seq_len(top_n)) {
    row <- high_outliers[i, ]
    write_line(sprintf(
      "  %-30s  %8.2f MiB  z = %6.2f",
      row$package,
      row$size_mib,
      row$z_score
    ))
  }
}

close(con)

## ------------------------ write outlier CSVs -------------------------##

if (nrow(high_outliers) > 0L) {
  out_high_path <- file.path(outdir, "pkg_size_outliers_high.csv")
  write.csv(high_outliers,
            file = out_high_path,
            row.names = FALSE)
}

if (nrow(low_outliers) > 0L) {
  out_low_path <- file.path(outdir, "pkg_size_outliers_low.csv")
  write.csv(low_outliers,
            file = out_low_path,
            row.names = FALSE)
}

## ------------------------ plots: histograms --------------------------##

## Linear scale histogram with overlaid normal curve
hist_linear_path <- file.path(outdir, "pkg_size_hist_linear.png")
png(hist_linear_path, width = 1200, height = 800)
sizes <- df$size_mib[is.finite(df$size_mib)]
hist_obj <- hist(
  sizes,
  breaks = 50L,
  main   = "Package size histogram (MiB)",
  xlab   = "Installed size (MiB)",
  col    = "grey",
  border = "white"
)

## Normal approximation with same mean and sd
if (!is.na(sd_mib) && sd_mib > 0) {
  x_seq <- seq(min(sizes, na.rm = TRUE),
               max(sizes, na.rm = TRUE),
               length.out = 1000L)
  y_norm <- dnorm(x_seq, mean = mean_mib, sd = sd_mib)
  ## Scale density to match histogram counts:
  bin_width <- diff(hist_obj$breaks)[1L]
  y_scaled  <- y_norm * length(sizes) * bin_width
  lines(x_seq, y_scaled, lwd = 2, col = "red")
}
dev.off()

## Log10 scale (handles heavy right tail more nicely)
log_sizes <- log10(sizes + 1e-6)  ## avoid log(0)
hist_log_path <- file.path(outdir, "pkg_size_hist_log10.png")
png(hist_log_path, width = 1200, height = 800)
hist(
  log_sizes,
  breaks = 50L,
  main   = "Package size histogram (log10 MiB)",
  xlab   = "log10(MiB)",
  col    = "grey",
  border = "white"
)
dev.off()
