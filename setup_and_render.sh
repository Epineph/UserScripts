#!/usr/bin/env bash
# setup_and_render.sh — install required R packages & render .Rmd → .pdf
#
# Usage:
#   ./setup_and_render.sh [ -i INPUT.Rmd ] [ -o OUTPUT.pdf ]
#
# Options:
#   -i, --input    Path to the .Rmd file (default: IQanalysis.Rmd)
#   -o, --output   Path to the .pdf file (default: same basename as INPUT)
#   -h, --help     Show this help message and exit
#
# This script:
#   1. Installs knitr & rmarkdown into your user R library
#   2. Installs TinyTeX (user‐level) if you don’t have a TeX engine
#   3. Calls `quarto render … --to pdf` to build the PDF

set -euo pipefail

# ——— Parse arguments ———
INPUT="IQanalysis.Rmd"
OUTPUT=""

print_help() {
  sed -n '1,8p' "$0"   # print the header comments as help
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -i|--input)
      INPUT="$2"
      shift 2
      ;;
    -o|--output)
      OUTPUT="$2"
      shift 2
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      print_help
      exit 1
      ;;
  esac
done

# ——— Define OUTPUT default if not set ———
if [[ -z "$OUTPUT" ]]; then
  BASE="${INPUT%.Rmd}"
  OUTPUT="${BASE}.pdf"
fi

echo "✅ Will render:"
echo "   Input:  $INPUT"
echo "   Output: $OUTPUT"

# ——— 1) Install knitr & rmarkdown in user library ———
echo "⏳ Installing knitr & rmarkdown (user library)…"
Rscript -e '
install.packages(
  c("knitr","rmarkdown"),
  repos="https://cloud.r-project.org",
  quiet=TRUE
)
'  

# ——— 2) Ensure TinyTeX (user-level TeX distro) ———
#echo "⏳ Ensuring TinyTeX is installed…"
#Rscript -e '
#if (!requireNamespace("tinytex", quietly=TRUE)) {
#  install.packages("tinytex", repos="https://cloud.r-project.org", quiet=TRUE)
#}
#if (!tinytex::is_tinytex()) tinytex::install_tinytex()
#'

# ——— 3) Render with Quarto ———
echo "⏳ Rendering $INPUT → $OUTPUT…"
quarto render "$INPUT" --to pdf --output-file="$OUTPUT"

echo "🎉 Done. Output available at $OUTPUT"

