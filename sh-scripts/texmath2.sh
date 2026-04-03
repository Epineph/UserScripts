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
#   - Default theme is white math on transparent background, intended for dark
#     terminals.
#   - By default, the formula is wrapped in \[ ... \]. Use --raw for raw LaTeX
#     environments such as align*, gathered, cases, etc.
#   - Transparent raster export is best done as PNG.
#   - Scalable/vector export is already available via --save-pdf.
#===============================================================================

function show_help() {
  cat <<'EOF'
texmath - Render LaTeX math in the terminal via chafa

USAGE
  texmath [OPTIONS] 'LATEX_MATH'
  printf '%s\n' '\begin{align*}a&=b+c\\d&=e+f\end{align*}' | \
    texmath --raw
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

INPUT
  -f, --file PATH            Read LaTeX input from PATH
  -r, --raw                  Treat input as raw LaTeX body; do not wrap in
                             \[ ... \]
  -e, --edit                 Open a temporary buffer in $EDITOR and render it
      --watch                Re-render on file changes (requires --file)

APPEARANCE
  -p, --preset NAME          Size preset: tiny, small, medium, large, huge
                             Default: medium
      --rows N               Maximum terminal row budget for the preview
      --cols N               Maximum terminal column budget for the preview
      --size COLSxROWS       Shorthand for setting both, e.g. 90x12
      --dpi N                Rasterization DPI for pdftocairo
                             Default: 300
      --font-size NAME       LaTeX size: normal, large, Large, LARGE, huge,
                             Huge
                             Default: Huge
      --fg COLOR             LaTeX foreground color
                             Default: white
      --bg MODE              Background mode: transparent, black
                             Default: transparent
      --border N             standalone border in pt
                             Default: 10
      --format NAME          chafa format: iterm, kitty, sixels, symbols
                             Default: iterm
      --optimize N           chafa optimize level 0-9
                             Default: 5

OUTPUT
      --save-pdf PATH        Copy rendered PDF to PATH
      --save-png PATH        Copy rendered PNG to PATH
      --save-transparent-png PATH
                             Export a transparent PNG regardless of preview
                             background
      --no-display           Do not preview in the terminal; export only
      --keep-temp            Keep the temporary working directory
      --print-tex            Print the generated .tex file path
      --show-paths           Print PDF/PNG paths after rendering

MISC
  -x, --examples             Show examples
  -h, --help                 Show this help

PRESETS
  tiny    ->  4 rows
  small   ->  6 rows
  medium  -> 10 rows
  large   -> 14 rows
  huge    -> 18 rows

NOTES
  - Presets only define rows. Columns default to your current terminal width
    unless you override them with --cols or --size.
  - PNG is the correct export format when you want a transparent bitmap image.
  - PDF is the better choice if you want vector/scalable output.

EXAMPLES
  texmath '\frac{a+b}{c+d}'

  texmath --cols 72 '\hat{\beta} = (X^\top X)^{-1}X^\top y'

  texmath --size 90x12 '\sum_{i=1}^{n}(x_i-\bar{x})^2'

  printf '%s\n' '\begin{align*}
  \mu &= \frac{1}{n}\sum_{i=1}^{n} x_i \\
  \sigma^2 &= \frac{1}{n}\sum_{i=1}^{n}(x_i-\mu)^2
  \end{align*}' | texmath --raw --cols 80 --preset medium

  texmath --save-transparent-png formula.png \
    '\Pr(Y=1\mid x)=\frac{1}{1+e^{-x}}'

  texmath --no-display --save-pdf formula.pdf \
    --save-transparent-png formula.png \
    '\int_0^\infty e^{-x^2}\,dx=\frac{\sqrt{\pi}}{2}'

EOF
}

function show_examples() {
  cat <<'EOF'
Examples:

1) Simple fraction
  texmath '\frac{a+b}{c+d}'

2) Regression estimator with manual preview width
  texmath --cols 72 '\hat{\beta} = (X^\top X)^{-1}X^\top y'

3) Set both preview width and height
  texmath --size 90x12 '\sum_{i=1}^{n}(x_i-\bar{x})^2'

4) Gaussian integral with transparent PNG export
  texmath --save-transparent-png gaussian.png \
    '\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}'

5) Raw align block from stdin
  printf '%s\n' '\begin{align*}
  \mu &= \frac{1}{n}\sum_{i=1}^{n} x_i \\
  \sigma^2 &= \frac{1}{n}\sum_{i=1}^{n}(x_i-\mu)^2
  \end{align*}' | texmath --raw --cols 80

6) Export only, no terminal preview
  texmath --no-display --save-pdf reg.pdf \
    --save-transparent-png reg.png \
    '\hat{y} = X\hat{\beta}'

7) Black preview background, but still export transparent PNG
  texmath --bg black --save-transparent-png logistic.png \
    '\Pr(Y=1\mid z)=\frac{1}{1+e^{-z}}'

8) Watch a file and re-render on change
  texmath --file formula.tex --raw --watch --cols 100

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
\hat{y} &= X\hat{\beta}
\end{align*}
EOF
}

function current_terminal_cols() {
  local cols=""

  if [[ -n "${COLUMNS:-}" ]] && [[ "${COLUMNS}" =~ ^[0-9]+$ ]]; then
    cols="${COLUMNS}"
  elif have_cmd tput; then
    cols="$(tput cols 2>/dev/null || true)"
  fi

  if [[ -z "${cols}" ]] || ! [[ "${cols}" =~ ^[0-9]+$ ]]; then
    cols="120"
  fi

  printf '%s\n' "${cols}"
}

function parse_size_argument() {
  local size_arg="$1"

  if [[ "${size_arg}" =~ ^([0-9]+)[xX]([0-9]+)$ ]]; then
    printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi

  die "Invalid --size value: ${size_arg} (use COLSxROWS, e.g. 90x12)"
}

function ensure_parent_dir() {
  local path="$1"
  local parent

  parent="$(dirname -- "$path")"
  mkdir -p -- "$parent"
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

function build_render_assets() {
  local tmpdir="$1"
  local stem="$2"
  local latex_body="$3"
  local raw_mode="$4"
  local font_size_cmd="$5"
  local fg_color="$6"
  local bg_mode="$7"
  local border_pt="$8"
  local dpi="$9"

  local tex_path="${tmpdir}/${stem}.tex"
  local pdf_path="${tmpdir}/${stem}.pdf"
  local png_base="${tmpdir}/${stem}"
  local png_path="${tmpdir}/${stem}.png"

  generate_tex_file \
    "$tex_path" \
    "$latex_body" \
    "$raw_mode" \
    "$font_size_cmd" \
    "$fg_color" \
    "$bg_mode" \
    "$border_pt"

  if ! tectonic "$tex_path" --outdir "$tmpdir" \
    >/dev/null 2>"${tmpdir}/${stem}.tectonic.stderr"; then
    cat "${tmpdir}/${stem}.tectonic.stderr" >&2
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
      return 1
    fi
  fi
}

function clear_screen_soft() {
  printf '\033[2J\033[H'
}

function render_once() {
  local latex_body="$1"
  local raw_mode="$2"
  local rows="$3"
  local cols="$4"
  local dpi="$5"
  local font_size_cmd="$6"
  local fg_color="$7"
  local bg_mode="$8"
  local border_pt="$9"
  local chafa_format="${10}"
  local optimize="${11}"
  local save_pdf="${12}"
  local save_png="${13}"
  local save_transparent_png="${14}"
  local no_display="${15}"
  local keep_temp="${16}"
  local print_tex="${17}"
  local show_paths="${18}"

  local tmpdir
  local main_tex_path
  local main_pdf_path
  local main_png_path
  local preview_cols

  tmpdir="$(mktemp -d)"
  main_tex_path="${tmpdir}/formula.tex"
  main_pdf_path="${tmpdir}/formula.pdf"
  main_png_path="${tmpdir}/formula.png"

  if ! build_render_assets \
    "$tmpdir" \
    "formula" \
    "$latex_body" \
    "$raw_mode" \
    "$font_size_cmd" \
    "$fg_color" \
    "$bg_mode" \
    "$border_pt" \
    "$dpi"; then
    [[ "$keep_temp" != "true" ]] && rm -rf -- "$tmpdir"
    return 1
  fi

  if [[ "$print_tex" == "true" ]]; then
    printf 'Generated TeX: %s\n' "$main_tex_path" >&2
  fi

  if [[ "$no_display" != "true" ]]; then
    if [[ -z "$cols" ]]; then
      preview_cols="$(current_terminal_cols)"
    else
      preview_cols="$cols"
    fi

    chafa \
      -f "$chafa_format" \
      -O "$optimize" \
      --size="${preview_cols}x${rows}" \
      "$main_png_path"
  fi

  if [[ -n "$save_pdf" ]]; then
    ensure_parent_dir "$save_pdf"
    cp -f -- "$main_pdf_path" "$save_pdf"
  fi

  if [[ -n "$save_png" ]]; then
    ensure_parent_dir "$save_png"
    cp -f -- "$main_png_path" "$save_png"
  fi

  if [[ -n "$save_transparent_png" ]]; then
    if [[ "$bg_mode" == "transparent" ]]; then
      ensure_parent_dir "$save_transparent_png"
      cp -f -- "$main_png_path" "$save_transparent_png"
    else
      if ! build_render_assets \
        "$tmpdir" \
        "formula_transparent" \
        "$latex_body" \
        "$raw_mode" \
        "$font_size_cmd" \
        "$fg_color" \
        "transparent" \
        "$border_pt" \
        "$dpi"; then
        [[ "$keep_temp" != "true" ]] && rm -rf -- "$tmpdir"
        return 1
      fi

      ensure_parent_dir "$save_transparent_png"
      cp -f -- "${tmpdir}/formula_transparent.png" "$save_transparent_png"
    fi
  fi

  if [[ "$show_paths" == "true" ]]; then
    printf '\nPDF: %s\nPNG: %s\n' "$main_pdf_path" "$main_png_path" >&2
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
  local raw_mode="$2"
  local rows="$3"
  local cols="$4"
  local dpi="$5"
  local font_size_cmd="$6"
  local fg_color="$7"
  local bg_mode="$8"
  local border_pt="$9"
  local chafa_format="${10}"
  local optimize="${11}"
  local save_pdf="${12}"
  local save_png="${13}"
  local save_transparent_png="${14}"
  local no_display="${15}"
  local keep_temp="${16}"
  local print_tex="${17}"
  local show_paths="${18}"

  local prev_hash=""
  local current_content=""
  local current_hash=""

  while true; do
    current_content="$(cat "$input_file")"
    current_hash="$(printf '%s' "$current_content" | sha256sum | awk '{print $1}')"

    if [[ "$current_hash" != "$prev_hash" ]]; then
      clear_screen_soft
      render_once \
        "$current_content" \
        "$raw_mode" \
        "$rows" \
        "$cols" \
        "$dpi" \
        "$font_size_cmd" \
        "$fg_color" \
        "$bg_mode" \
        "$border_pt" \
        "$chafa_format" \
        "$optimize" \
        "$save_pdf" \
        "$save_png" \
        "$save_transparent_png" \
        "$no_display" \
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
  local cols=""
  local dpi="300"
  local font_size="Huge"
  local fg_color="white"
  local bg_mode="transparent"
  local border_pt="10"
  local chafa_format="iterm"
  local optimize="5"
  local save_pdf=""
  local save_png=""
  local save_transparent_png=""
  local no_display="false"
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
      --cols)
        [[ $# -ge 2 ]] || die "--cols requires a value"
        cols="$2"
        shift 2
        ;;
      --size)
        [[ $# -ge 2 ]] || die "--size requires a value"
        read -r cols rows <<< "$(parse_size_argument "$2")"
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
      --save-transparent-png)
        [[ $# -ge 2 ]] || die "--save-transparent-png requires a path"
        save_transparent_png="$2"
        shift 2
        ;;
      --no-display)
        no_display="true"
        shift
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
  (( rows > 0 )) || die "--rows must be greater than 0"

  if [[ -n "$cols" ]]; then
    [[ "$cols" =~ ^[0-9]+$ ]] || die "--cols must be an integer"
    (( cols > 0 )) || die "--cols must be greater than 0"
  fi

  [[ "$dpi" =~ ^[0-9]+$ ]] || die "--dpi must be an integer"
  (( dpi > 0 )) || die "--dpi must be greater than 0"

  [[ "$border_pt" =~ ^[0-9]+$ ]] || die "--border must be an integer"
  (( border_pt >= 0 )) || die "--border must be 0 or greater"

  [[ "$optimize" =~ ^[0-9]+$ ]] || die "--optimize must be an integer"
  (( optimize >= 0 && optimize <= 9 )) || die "--optimize must be 0-9"

  local font_size_cmd
  font_size_cmd="$(normalize_font_size "$font_size")"

  if [[ "$watch_mode" == "true" ]]; then
    [[ -n "$input_file" ]] || die "--watch currently requires --file"
    [[ "$edit_mode" != "true" ]] || die "--watch does not pair with --edit"

    watch_loop \
      "$input_file" \
      "$raw_mode" \
      "$rows" \
      "$cols" \
      "$dpi" \
      "$font_size_cmd" \
      "$fg_color" \
      "$bg_mode" \
      "$border_pt" \
      "$chafa_format" \
      "$optimize" \
      "$save_pdf" \
      "$save_png" \
      "$save_transparent_png" \
      "$no_display" \
      "$keep_temp" \
      "$print_tex" \
      "$show_paths"
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
    "$cols" \
    "$dpi" \
    "$font_size_cmd" \
    "$fg_color" \
    "$bg_mode" \
    "$border_pt" \
    "$chafa_format" \
    "$optimize" \
    "$save_pdf" \
    "$save_png" \
    "$save_transparent_png" \
    "$no_display" \
    "$keep_temp" \
    "$print_tex" \
    "$show_paths"
}

main "$@"
