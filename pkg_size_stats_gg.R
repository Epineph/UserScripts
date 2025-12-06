#!/usr/bin/env Rscript

## ---------------------------------------------------------------------##
##  pkg_size_stats_gg.R                                                 ##
##                                                                       ##
##  Analyse Arch package size report CSV from sort-pkg-by-size-report   ##
##  using tidyverse + ggplot2.                                           ##
##                                                                       ##
##  Inputs                                                               ##
##  ------                                                               ##
##  1. Path to pkg_by_size_report.csv                                    ##
##  2. Optional: output directory (default = directory of the CSV)       ##
##  3. Optional: z-score threshold (default = 2.0)                       ##
##                                                                       ##
##  Outputs                                                              ##
##  -------                                                              ##
##  - pkg_size_summary.txt                                               ##
##  - pkg_size_outliers_high.csv                                         ##
##  - pkg_size_outliers_low.csv                                          ##
##  - pkg_size_hist_linear_gg.png                                        ##
##  - pkg_size_hist_log10_gg.png                                         ##
##  - pkg_size_topN_lollipop_gg.png                                      ##
##                                                                       ##
##  Mathematical core                                                    ##
##  -----------------                                                    ##
##  Let x_i be package sizes in MiB, i = 1, ..., n.                      ##
##                                                                       ##
##    Mean:   mu = (1/n) * sum_{i=1}^n x_i                               ##
##    Var:    s^2 = (1/(n-1)) * sum_{i=1}^n (x_i - mu)^2                ##
##    SD:     s = sqrt(s^2)                                              ##
##                                                                       ##
##    z-score for each package:                                          ##
##      z_i = (x_i - mu) / s                                             ##
##                                                                       ##
##  High outlier if:   z_i >= z_thr                                      ##
##  Low  outlier if:   z_i <= -z_thr                                     ##
## ---------------------------------------------------------------------##

suppressPackageStartupMessages({
  has_readr    <- requireNamespace("readr",    quietly = TRUE)
  has_dplyr    <- requireNamespace("dplyr",    quietly = TRUE)
  has_ggplot2  <- requireNamespace("ggplot2",  quietly = TRUE)
  has_scales   <- requireNamespace("scales",   quietly = TRUE)
  has_patchwork<- requireNamespace("patchwork",quietly = TRUE)
})

needed <- c("readr", "dplyr", "ggplot2", "scales")
missing <- needed[!vapply(
  needed,
  function(pkg) requireNamespace(pkg, quietly = TRUE),
  logical(1L)
)]

if (length(missing) > 0L) {
  stop(
    "Missing required packages: ",
    paste(missing, collapse = ", "),
    "\nInstall them in R with:\n  install.packages(c(",
    paste(sprintf('"%s"', missing), collapse = ", "),
    "))",
    call. = FALSE
  )
}

library(readr)
library(dplyr)
library(ggplot2)
library(scales)
if (has_patchwork) {
  library(patchwork)
}

## ------------------------ argument parsing ---------------------------##

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 1L) {
  cat(
    "Usage:\n",
    "  pkg_size_stats_gg.R /path/to/pkg_by_size_report.csv [outdir] [z_thr]\n\n",
    "Examples:\n",
    "  pkg_size_stats_gg.R ",
    "~/exported_csv_logs/sort_pkg_by_size/20251206_084151/pkg_by_size_report.csv\n",
    "  pkg_size_stats_gg.R path/to/csv /tmp 2.5\n",
    sep = ""
  )
  quit(status = 1L)
}

csv_path <- normalizePath(args[1L])
outdir   <- if (length(args) >= 2L) normalizePath(args[2L]) else dirname(csv_path)
z_thr    <- if (length(args) >= 3L) as.numeric(args[3L]) else 2.0

if (!file.exists(csv_path)) {
  stop("Input CSV does not exist: ", csv_path, call. = FALSE)
}
if (!dir.exists(outdir)) {
  dir.create(outdir, recursive = TRUE, showWarnings = FALSE)
}
if (!is.finite(z_thr) || z_thr <= 0) {
  stop("z_thr must be a positive numeric value.", call. = FALSE)
}

## ------------------------ data import --------------------------------##

df <- readr::read_csv(csv_path, show_col_types = FALSE)

required_cols <- c("package", "size_kib")
missing_cols  <- setdiff(required_cols, names(df))
if (length(missing_cols) > 0L) {
  stop(
    "CSV is missing required columns: ",
    paste(missing_cols, collapse = ", "),
    call. = FALSE
  )
}

df <- df %>%
  mutate(
    size_kib = as.numeric(size_kib),
    size_mib = size_kib / 1024,
    size_gib = size_mib / 1024
  )

## Drop any NA sizes just to avoid pollution
df <- df %>% filter(is.finite(size_mib))

## ------------------------ summary statistics -------------------------##

n_pkgs    <- nrow(df)
total_kib <- sum(df$size_kib, na.rm = TRUE)
total_gib <- total_kib / (1024 ^ 2)

mean_mib   <- mean(df$size_mib,   na.rm = TRUE)
median_mib <- median(df$size_mib, na.rm = TRUE)
sd_mib     <- sd(df$size_mib,     na.rm = TRUE)

quantiles <- quantile(
  df$size_mib,
  probs = c(0.25, 0.50, 0.75, 0.90, 0.95, 0.99),
  na.rm = TRUE
)

if (is.na(sd_mib) || sd_mib == 0) {
  df <- df %>%
    mutate(z_score = NA_real_)
} else {
  df <- df %>%
    mutate(z_score = (size_mib - mean_mib) / sd_mib)
}

## Outlier flags
df <- df %>%
  mutate(
    outlier_type = case_when(
      !is.na(z_score) & z_score >=  z_thr ~ "high",
      !is.na(z_score) & z_score <= -z_thr ~ "low",
      TRUE                                ~ "none"
    )
  )

high_outliers <- df %>%
  filter(outlier_type == "high") %>%
  arrange(desc(size_mib))

low_outliers <- df %>%
  filter(outlier_type == "low") %>%
  arrange(size_mib)

## ------------------------ write summary text -------------------------##

summary_path <- file.path(outdir, "pkg_size_summary.txt")
con <- file(summary_path, open = "wt")

write_line <- function(...) cat(paste0(..., "\n"), file = con)

write_line("Package size statistics (tidyverse + ggplot2)")
write_line("------------------------------------------------")
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
for (i in seq_along(quantiles)) {
  write_line(
    sprintf("  %5.2f %% : %.2f",
            as.numeric(names(quantiles)[i]) * 100,
            quantiles[[i]])
  )
}
write_line("")
write_line("Outlier definition:")
write_line("  z_i = (x_i - mean) / sd")
write_line(sprintf("  High outliers : z_i >=  %.2f", z_thr))
write_line(sprintf("  Low  outliers : z_i <= -%.2f", z_thr))
write_line("")
write_line(sprintf("High outliers count (z >= %.2f): %d", z_thr,
                   nrow(high_outliers)))
write_line(sprintf("Low  outliers count (z <= -%.2f): %d", z_thr,
                   nrow(low_outliers)))

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
  readr::write_csv(high_outliers, out_high_path)
}

if (nrow(low_outliers) > 0L) {
  out_low_path <- file.path(outdir, "pkg_size_outliers_low.csv")
  readr::write_csv(low_outliers, out_low_path)
}

## ------------------------ plotting aesthetics ------------------------##

base_theme <- theme_minimal(base_size = 13) +
  theme(
    plot.title   = element_text(face = "bold", hjust = 0.0),
    plot.subtitle= element_text(hjust = 0.0),
    panel.grid.minor = element_blank()
  )

## ------------------------ Plot 1: linear histogram -------------------##

hist_linear_path <- file.path(outdir, "pkg_size_hist_linear_gg.png")

## For a more readable histogram, cap at the 99th percentile
x_max <- as.numeric(quantile(df$size_mib, 0.99, na.rm = TRUE))

p_hist_lin <- ggplot(df, aes(x = size_mib)) +
  geom_histogram(
    aes(y = after_stat(..density..)),
    bins    = 50L,
    fill    = "#4C72B0",
    colour  = "white",
    alpha   = 0.80
  ) +
  coord_cartesian(xlim = c(0, x_max)) +
  {
    if (!is.na(sd_mib) && sd_mib > 0) {
      stat_function(
        fun  = dnorm,
        args = list(mean = mean_mib, sd = sd_mib),
        colour   = "#DD8452",
        linewidth = 1.0
      )
    } else {
      NULL
    }
  } +
  labs(
    title    = "Package size distribution (MiB)",
    subtitle = sprintf(
      "n = %d, mean = %.1f MiB, median = %.1f MiB, sd = %.1f MiB",
      n_pkgs, mean_mib, median_mib, sd_mib
    ),
    x = "Installed size (MiB) [truncated at 99th percentile]",
    y = "Density"
  ) +
  base_theme

ggsave(
  filename = hist_linear_path,
  plot     = p_hist_lin,
  width    = 9,
  height   = 6,
  dpi      = 150
)

## ------------------------ Plot 2: log10 histogram --------------------##

hist_log_path <- file.path(outdir, "pkg_size_hist_log10_gg.png")

df <- df %>%
  mutate(log10_size_mib = log10(size_mib + 1e-6))

p_hist_log <- ggplot(df, aes(x = log10_size_mib)) +
  geom_histogram(
    bins    = 50L,
    fill    = "#55A868",
    colour  = "white",
    alpha   = 0.80
  ) +
  labs(
    title    = "Package size distribution (log10 MiB)",
    subtitle = "Right tail compressed by log10 transform",
    x        = "log10(Installed size (MiB))",
    y        = "Count"
  ) +
  base_theme

ggsave(
  filename = hist_log_path,
  plot     = p_hist_log,
  width    = 9,
  height   = 6,
  dpi      = 150
)

## ------------------------ Plot 3: top N lollipop ---------------------##

topN <- 60L   ## you can adjust this if you like
top_df <- df %>%
  arrange(desc(size_mib)) %>%
  slice_head(n = topN) %>%
  mutate(
    package = forcats::fct_reorder(package, size_mib),
    is_high_outlier = outlier_type == "high"
  )

lollipop_path <- file.path(outdir, "pkg_size_topN_lollipop_gg.png")

p_lollipop <- ggplot(top_df, aes(x = package, y = size_mib)) +
  geom_segment(
    aes(xend = package, y = 0, yend = size_mib),
    colour = "grey70",
    linewidth = 0.6
  ) +
  geom_point(
    aes(colour = z_score, size = is_high_outlier),
    alpha = 0.9
  ) +
  scale_colour_distiller(
    palette = "Spectral",
    direction = -1,
    name = "z-score"
  ) +
  scale_size_manual(
    values = c("FALSE" = 2.0, "TRUE" = 3.5),
    guide  = "none"
  ) +
  coord_flip() +
  labs(
    title    = sprintf("Top %d largest packages (MiB)", topN),
    subtitle = sprintf(
      "Colour = z-score; dot size marks high outliers (z >= %.1f)",
      z_thr
    ),
    x = NULL,
    y = "Installed size (MiB)"
  ) +
  base_theme +
  theme(
    axis.text.y = element_text(size = 8)
  )

ggsave(
  filename = lollipop_path,
  plot     = p_lollipop,
  width    = 9,
  height   = 10,
  dpi      = 150
)

## ------------------------ Optional combined plot ---------------------##
## If patchwork is available, create a side-by-side summary plot.

if (has_patchwork) {
  combo_path <- file.path(outdir, "pkg_size_summary_panel_gg.png")
  combo_plot <- (p_hist_lin | p_hist_log) / p_lollipop +
    plot_annotation(
      title = "Package size diagnostics",
      subtitle = sprintf(
        "High outliers: %d  |  Low outliers: %d  |  z-threshold = %.1f",
        nrow(high_outliers), nrow(low_outliers), z_thr
      )
    )
  ggsave(
    filename = combo_path,
    plot     = combo_plot,
    width    = 12,
    height   = 12,
    dpi      = 150
  )
}

## ------------------------ final message ------------------------------##

cat("Analysis complete.\n")
cat("Summary text   :", summary_path, "\n")
if (nrow(high_outliers) > 0L) {
  cat("High outliers  : pkg_size_outliers_high.csv\n")
}
if (nrow(low_outliers) > 0L) {
  cat("Low outliers   : pkg_size_outliers_low.csv\n")
}
cat("Plots written  :\n")
cat("  -", hist_linear_path, "\n")
cat("  -", hist_log_path,    "\n")
cat("  -", lollipop_path,    "\n")
if (has_patchwork) {
  cat("  - pkg_size_summary_panel_gg.png\n")
}
