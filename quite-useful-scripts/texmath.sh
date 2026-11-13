#!/usr/bin/env bash

set -euo pipefail

#===============================================================================
# texmath
#
# Render LaTeX math directly in the terminal using:
#   LaTeX -> PDF -> PNG -> chafa
#
# Designed for terminals that can display inline images well, such as WezTerm.
#
# Dependencies:
#   - tectonic
#   - pdftocairo  (from poppler)
#   - chafa
#
# Optional:
#   - $EDITOR     (for --edit)
#
# Notes:
#   - Default theme is white math on transparent background, intended for
#     dark terminals.
#   - The script uses standalone+preview to render displayed math reliably.
#   - By default, the formula is wrapped in \[ ... \]. Use --raw for raw
#     LaTeX environments such as align*, gathered, cases, etc.
#===============================================================================

function show_help() {
  cat <<'EOF'
texmath - Render LaTeX math in the terminal via chafa

USAGE
  texmath [OPTIONS] 'LATEX_MATH'
  printf '%s\n' '\begin{align*}a&=b+c\\d&=e+f\end{align*}' | texmath --raw
  texmath --edit
  texmath --file formula.tex --raw

DESCRIPTION
  By default, texmath treats the input as math content and wraps it in:

    \[
      ...
    \]

  Use --raw when the input already contains its own environment, e.g.:

    \begin{align*}
      ...
    \end{align*}

OPTIONS
  Input:
    -f, --file PATH          Read LaTeX input from PATH
    -r, --raw                Treat input as raw LaTeX body; do not wrap in \[
                             ... \]
    -e, --edit               Open a temporary buffer in $EDITOR and render it
        --watch              With --edit or --file, rerender when content
                             changes. Poll-based; no extra dependency required.

  Appearance:
    -p, --preset NAME        Size preset: tiny, small, medium, large, huge
                             Default: medium
        --rows N             Maximum terminal row budget for the image
        --dpi N              Rasterization DPI for pdftocairo
                             Default: 300
        --font-size NAME     LaTeX size: normal, large, Large, LARGE, huge,
                             Huge
                             Default: Huge
        --fg COLOR           LaTeX foreground color
                             Default: white
        --bg MODE            Background mode: transparent, black
                             Default: transparent
        --border N           standalone border in pt
                             Default: 10
        --format NAME        chafa format: iterm, kitty, sixels, symbols
                             Default: iterm
        --optimize N         chafa optimize level 0-9
                             Default: 5

  Output control:
        --save-pdf PATH      Copy rendered PDF to PATH
        --save-png PATH      Copy rendered PNG to PATH
        --keep-temp          Keep the temporary working directory
        --print-tex          Print the generated .tex file path
        --show-paths         Print PDF/PNG paths after rendering

  Misc:
    -x, --examples           Show examples
    -h, --help               Show this help

PRESETS
  tiny    ->  4 rows
  small   ->  6 rows
  medium  -> 10 rows
  large   -> 14 rows
  huge    -> 18 rows

EXAMPLES
  texmath '\frac{a+b}{c+d}'

  texmath '\hat{\beta} = (X^\top X)^{-1}X^\top y'

  texmath --preset small '\sum_{i=1}^{n}(x_i-\bar{x})^2'

  printf '%s\n' '\begin{align*}
  \mu &= \frac{1}{n}\sum_{i=1}^{n} x_i \\
  \sigma^2 &= \frac{1}{n}\sum_{i=1}^{n}(x_i-\mu)^2
  \end{align*}' | texmath --raw

  texmath --bg black --fg white '\Pr(Y=1\mid x)=\frac{1}{1+e^{-x}}'

  texmath --file my_formula.tex --raw --watch

EOF
}

function show_examples() {
  cat <<'EOF'
Examples:

1) Simple fraction
  texmath '\frac{a+b}{c+d}'

2) Regression estimator
  texmath '\hat{\beta} = (X^\top X)^{-1}X^\top y'

3) Gaussian integral
  texmath '\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}'

4) Small display
  texmath --preset small '\sum_{i=1}^{n}(x_i-\bar{x})^2'

5) Logistic model
  texmath '\Pr(Y=1\mid z) = \frac{1}{1+e^{-(\beta_0+\beta_1 z)}}'

6) Raw align block from stdin
  printf '%s\n' '\begin{align*}
  \mu &= \frac{1}{n}\sum_{i=1}^{n} x_i \\
  \sigma^2 &= \frac{1}{n}\sum_{i=1}^{n}(x_i-\mu)^2
  \end{align*}' | texmath --raw

7) Edit interactively
  texmath --edit

8) Black background baked into the image
  texmath --bg black '\frac{\partial \ell}{\partial \beta} = X^\top(y-\mu)'

EOF
}

function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

function require_cmds() {
  local missing=()

  for cmd in tectonic pdftocairo chafa; do
    if ! have_cmd "$cmd"; then
      missing+=("$cmd")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    printf 'Missing required command(s): %s\n' "${missing[*]}" >&2
    printf 'Install with:\n' >&2
    printf '  sudo pacman -S tectonic poppler chafa\n' >&2
    exit 1
  fi
}

function normalize_preset_to_rows() {
  local preset
  preset="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

  case "$preset" in
    tiny)   printf '4\n' ;;
    small)  printf '6\n' ;;
    medium) printf '10\n' ;;
    large)  printf '14\n' ;;
    huge)   printf '18\n' ;;
    *)
      die "Invalid preset: $1"
      ;;
  esac
}

function normalize_font_size() {
  local size
  size="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

  case "$size" in
    normal) printf '\\normalsize\n' ;;
    large)  printf '\\large\n' ;;
    large2) printf '\\Large\n' ;;
    large3) printf '\\LARGE\n' ;;
    huge)   printf '\\huge\n' ;;
    huge2)  printf '\\Huge\n' ;;
    *)
      case "$1" in
        normal|large|Large|LARGE|huge|Huge)
          printf '\\%s\n' "$1"
          ;;
        *)
          die \
            "Invalid --font-size: $1 (use normal, large, Large, LARGE, huge, Huge)"
          ;;
      esac
      ;;
  esac
}

function editor_default_content() {
  cat <<'EOF'
\begin{align*}
\hat{\beta} &= (X^\top X)^{-1}X^\top y \\
\ell(\beta) &= \sum_{i=1}^{n} y_i \log p_i + (1-y_i)\log(1-p_i)
\end{align*}
EOF
}

function generate_tex_file() {
  local tex_path="$1"
  local latex_body="$2"
  local raw_mode="$3"
  local font_size_cmd="$4"
  local fg_color="$5"
  local bg_mode="$6"
  local border_pt="$7"

  {
    printf '\\documentclass[border=%spt,preview]{standalone}\n' "$border_pt"
    printf '\\usepackage{amsmath,amssymb,mathtools}\n'
    printf '\\usepackage{xcolor}\n'

    if [[ "$bg_mode" == "black" ]]; then
      printf '\\pagecolor{black}\n'
    fi

    printf '\\begin{document}\n'
    printf '{\\color{%s}%s\n' "$fg_color" "$font_size_cmd"

    if [[ "$raw_mode" == "true" ]]; then
      printf '%s\n' "$latex_body"
    else
      printf '\\[\n%s\n\\]\n' "$latex_body"
    fi

    printf '}\n'
    printf '\\end{document}\n'
  } > "$tex_path"
}

function render_once() {
  local latex_body="$1"
  local raw_mode="$2"
  local rows="$3"
  local dpi="$4"
  local font_size_cmd="$5"
  local fg_color="$6"
  local bg_mode="$7"
  local border_pt="$8"
  local chafa_format="$9"
  local optimize="${10}"
  local save_pdf="${11}"
  local save_png="${12}"
  local keep_temp="${13}"
  local print_tex="${14}"
  local show_paths="${15}"

  local tmpdir
  local tex_path
  local pdf_path
  local png_base
  local png_path
  local cols

  tmpdir="$(mktemp -d)"
  tex_path="${tmpdir}/formula.tex"
  pdf_path="${tmpdir}/formula.pdf"
  png_base="${tmpdir}/formula"
  png_path="${tmpdir}/formula.png"



  generate_tex_file \
    "$tex_path" \
    "$latex_body" \
    "$raw_mode" \
    "$font_size_cmd" \
    "$fg_color" \
    "$bg_mode" \
    "$border_pt"

  if [[ "$print_tex" == "true" ]]; then
    printf 'Generated TeX: %s\n' "$tex_path" >&2
  fi

   if ! tectonic "$tex_path" --outdir "$tmpdir" \
    >/dev/null 2>"${tmpdir}/tectonic.stderr"; then
    cat "${tmpdir}/tectonic.stderr" >&2
    [[ "$keep_temp" != "true" ]] && rm -rf -- "$tmpdir"
    return 1
  fi

    if [[ "$bg_mode" == "transparent" ]]; then
    if ! pdftocairo \
      -png \
      -singlefile \
      -r "$dpi" \
      -transp \
      "$pdf_path" \
      "$png_base" \
      >/dev/null 2>&1; then
      printf 'Error: pdftocairo failed.\n' >&2
      [[ "$keep_temp" != "true" ]] && rm -rf -- "$tmpdir"
      return 1
    fi
  else
    if ! pdftocairo \
      -png \
      -singlefile \
      -r "$dpi" \
      "$pdf_path" \
      "$png_base" \
      >/dev/null 2>&1; then
      printf 'Error: pdftocairo failed.\n' >&2
      [[ "$keep_temp" != "true" ]] && rm -rf -- "$tmpdir"
      return 1
    fi
  fi

  cols="${COLUMNS:-120}"

  chafa \
    -f "$chafa_format" \
    -O "$optimize" \
    --size="${cols}x${rows}" \
    "$png_path"

  if [[ -n "$save_pdf" ]]; then
    cp -f "$pdf_path" "$save_pdf"
  fi

  if [[ -n "$save_png" ]]; then
    cp -f "$png_path" "$save_png"
  fi

  if [[ "$show_paths" == "true" ]]; then
    printf '\nPDF: %s\nPNG: %s\n' "$pdf_path" "$png_path" >&2
  fi

  if [[ "$keep_temp" == "true" ]]; then
    printf '\nTemporary directory kept: %s\n' "$tmpdir" >&2
  else
    rm -rf -- "$tmpdir"
  fi

}

function read_input_content() {
  local input_file="$1"
  local edit_mode="$2"
  local raw_mode="$3"
  shift 3
  local args=("$@")

  local content
  local editor_cmd
  local tmp_input

  if [[ -n "$input_file" ]]; then
    [[ -f "$input_file" ]] || die "Input file not found: $input_file"
    cat "$input_file"
    return 0
  fi

  if [[ "$edit_mode" == "true" ]]; then
    editor_cmd="${EDITOR:-vi}"
    tmp_input="$(mktemp)"
    editor_default_content > "$tmp_input"
    "$editor_cmd" "$tmp_input"
    cat "$tmp_input"
    rm -f "$tmp_input"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    cat
    return 0
  fi

  if (( ${#args[@]} > 0 )); then
    printf '%s' "${args[*]}"
    return 0
  fi

  if [[ "$raw_mode" == "true" ]]; then
    die "No raw LaTeX input provided"
  fi

  die "No math input provided"
}

function watch_loop() {
  local input_file="$1"
  local edit_mode="$2"
  local raw_mode="$3"
  local rows="$4"
  local dpi="$5"
  local font_size_cmd="$6"
  local fg_color="$7"
  local bg_mode="$8"
  local border_pt="$9"
  local chafa_format="${10}"
  local optimize="${11}"
  local save_pdf="${12}"
  local save_png="${13}"
  local keep_temp="${14}"
  local print_tex="${15}"
  local show_paths="${16}"
  shift 16
  local args=("$@")

  local prev_hash=""
  local current_content=""
  local current_hash=""

  while true; do
    current_content="$(
      read_input_content "$input_file" "$edit_mode" "$raw_mode" "${args[@]}"
    )"

    current_hash="$(
      printf '%s' "$current_content" | sha256sum | awk '{print $1}'
    )"

    if [[ "$current_hash" != "$prev_hash" ]]; then
      printf '\033c'
      render_once \
        "$current_content" \
        "$raw_mode" \
        "$rows" \
        "$dpi" \
        "$font_size_cmd" \
        "$fg_color" \
        "$bg_mode" \
        "$border_pt" \
        "$chafa_format" \
        "$optimize" \
        "$save_pdf" \
        "$save_png" \
        "$keep_temp" \
        "$print_tex" \
        "$show_paths"
      prev_hash="$current_hash"
    fi

    sleep 0.6
  done
}

function main() {
  local raw_mode="false"
  local edit_mode="false"
  local watch_mode="false"
  local input_file=""
  local preset="medium"
  local rows=""
  local dpi="300"
  local font_size="Huge"
  local fg_color="white"
  local bg_mode="transparent"
  local border_pt="10"
  local chafa_format="iterm"
  local optimize="5"
  local save_pdf=""
  local save_png=""
  local keep_temp="false"
  local print_tex="false"
  local show_paths="false"

  local args=()

  require_cmds

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        show_help
        exit 0
        ;;
      -x|--examples)
        show_examples
        exit 0
        ;;
      -r|--raw)
        raw_mode="true"
        shift
        ;;
      -e|--edit)
        edit_mode="true"
        raw_mode="true"
        shift
        ;;
      --watch)
        watch_mode="true"
        shift
        ;;
      -f|--file)
        [[ $# -ge 2 ]] || die "--file requires a path"
        input_file="$2"
        shift 2
        ;;
      -p|--preset)
        [[ $# -ge 2 ]] || die "--preset requires a value"
        preset="$2"
        shift 2
        ;;
      --rows)
        [[ $# -ge 2 ]] || die "--rows requires a value"
        rows="$2"
        shift 2
        ;;
      --dpi)
        [[ $# -ge 2 ]] || die "--dpi requires a value"
        dpi="$2"
        shift 2
        ;;
      --font-size)
        [[ $# -ge 2 ]] || die "--font-size requires a value"
        font_size="$2"
        shift 2
        ;;
      --fg)
        [[ $# -ge 2 ]] || die "--fg requires a value"
        fg_color="$2"
        shift 2
        ;;
      --bg)
        [[ $# -ge 2 ]] || die "--bg requires a value"
        bg_mode="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
        shift 2
        ;;
      --border)
        [[ $# -ge 2 ]] || die "--border requires a value"
        border_pt="$2"
        shift 2
        ;;
      --format)
        [[ $# -ge 2 ]] || die "--format requires a value"
        chafa_format="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
        shift 2
        ;;
      --optimize)
        [[ $# -ge 2 ]] || die "--optimize requires a value"
        optimize="$2"
        shift 2
        ;;
      --save-pdf)
        [[ $# -ge 2 ]] || die "--save-pdf requires a path"
        save_pdf="$2"
        shift 2
        ;;
      --save-png)
        [[ $# -ge 2 ]] || die "--save-png requires a path"
        save_png="$2"
        shift 2
        ;;
      --keep-temp)
        keep_temp="true"
        shift
        ;;
      --print-tex)
        print_tex="true"
        shift
        ;;
      --show-paths)
        show_paths="true"
        shift
        ;;
      --)
        shift
        while (( $# > 0 )); do
          args+=("$1")
          shift
        done
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done

  case "$bg_mode" in
    transparent|black) ;;
    *)
      die "Invalid --bg value: $bg_mode (use transparent or black)"
      ;;
  esac

  case "$chafa_format" in
    iterm|kitty|sixels|symbols) ;;
    *)
      die \
        "Invalid --format value: $chafa_format (use iterm, kitty, sixels, symbols)"
      ;;
  esac

  if [[ -z "$rows" ]]; then
    rows="$(normalize_preset_to_rows "$preset")"
  fi

  [[ "$rows" =~ ^[0-9]+$ ]] || die "--rows must be an integer"
  [[ "$dpi" =~ ^[0-9]+$ ]] || die "--dpi must be an integer"
  [[ "$border_pt" =~ ^[0-9]+$ ]] || die "--border must be an integer"
  [[ "$optimize" =~ ^[0-9]+$ ]] || die "--optimize must be an integer"

  local font_size_cmd
  font_size_cmd="$(normalize_font_size "$font_size")"

  if [[ "$watch_mode" == "true" ]]; then
    if [[ "$edit_mode" == "true" ]]; then
      die "--watch does not pair well with --edit in this implementation; use --file"
    fi

    watch_loop \
      "$input_file" \
      "$edit_mode" \
      "$raw_mode" \
      "$rows" \
      "$dpi" \
      "$font_size_cmd" \
      "$fg_color" \
      "$bg_mode" \
      "$border_pt" \
      "$chafa_format" \
      "$optimize" \
      "$save_pdf" \
      "$save_png" \
      "$keep_temp" \
      "$print_tex" \
      "$show_paths" \
      "${args[@]}"
    exit 0
  fi

  local latex_body
  latex_body="$(
    read_input_content "$input_file" "$edit_mode" "$raw_mode" "${args[@]}"
  )"

  render_once \
    "$latex_body" \
    "$raw_mode" \
    "$rows" \
    "$dpi" \
    "$font_size_cmd" \
    "$fg_color" \
    "$bg_mode" \
    "$border_pt" \
    "$chafa_format" \
    "$optimize" \
    "$save_pdf" \
    "$save_png" \
    "$keep_temp" \
    "$print_tex" \
    "$show_paths"
}

main "$@"
