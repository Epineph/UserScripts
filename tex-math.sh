#!/usr/bin/env bash

set -euo pipefail

#===============================================================================
# texmath
#
# Render LaTeX/math in the terminal:
#
#   LaTeX body -> generated .tex -> PDF -> PNG -> chafa
#
# Dependencies:
#   - tectonic
#   - pdftocairo  (from poppler)
#   - chafa
#
# Design notes:
#   - Default mode is math mode: input is wrapped in \[ ... \].
#   - --raw inserts input directly into the document body.
#   - --text inserts input into a varwidth text block.
#   - --preamble and --preamble-file allow commands such as
#     \DeclareMathOperator, \newcommand, \usepackage, etc.
#   - Temporary files are kept automatically on errors.
#===============================================================================

function show_help() {
  cat <<'EOF'
texmath - Render LaTeX/math in the terminal via tectonic, pdftocairo, chafa

USAGE
  texmath [OPTIONS] 'LATEX'
  texmath --raw '\begin{align*}a&=b\\c&=d\end{align*}'
  texmath --text 'Plain LaTeX text body'
  texmath --file formula.tex --raw
  printf '%s\n' '\hat{\beta}=X^\top y' | texmath

INPUT MODES
  Default math mode:
    The input is wrapped in:

      \[
        ...
      \]

    Good for ordinary formula fragments and environments that require math mode,
    e.g. aligned, cases, matrix.

  -r, --raw, --body
    Insert the input directly into the LaTeX document body.

    Good for top-level display environments, e.g.:

      \begin{align*}
        ...
      \end{align*}

  -t, --text
    Insert the input into a varwidth text block.

    Good for explanatory text, short paragraphs, and mixed text/math.

INPUT SOURCES
  -f, --file PATH
    Read LaTeX input from PATH.

  -e, --edit
    Open a temporary buffer in $EDITOR and render it. Implies --raw.

  --watch
    Re-render on file changes. Requires --file.

PREAMBLE
  --preamble TEX
    Add one raw LaTeX line/block to the generated preamble. May be repeated.

  --preamble-file PATH
    Add all contents of PATH to the generated preamble. May be repeated.

  This is the correct place for commands such as:

    \DeclareMathOperator{\modmax}{Mod_{\max}}
    \newcommand{\R}{\mathbb{R}}
    \usepackage{siunitx}

APPEARANCE
  -p, --preset NAME
    Size preset: tiny, small, medium, large, huge.
    Default: medium.

  --rows N
    Maximum terminal row budget for the preview.

  --cols N
    Maximum terminal column budget for the preview.

  --size COLSxROWS
    Shorthand for both, e.g. 90x12.

  --dpi N
    Rasterization DPI for pdftocairo.
    Default: 300.

  --font-size NAME
    LaTeX size: tiny, scriptsize, footnotesize, small, normal, large,
    Large, LARGE, huge, Huge.
    Default: Huge.

  --fg COLOR
    LaTeX foreground color.
    Default: white.

  --bg MODE
    Background mode: transparent, black, white.
    Default: transparent.

  --border N
    standalone border in pt.
    Default: 10.

  --format NAME
    chafa format: auto, kitty, iterm, sixels, symbols.
    Default: auto.

  --optimize N
    chafa optimize level 0-9.
    Default: 5.

OUTPUT
  --save-pdf PATH
    Copy rendered PDF to PATH.

  --save-png PATH
    Copy rendered PNG to PATH.

  --save-transparent-png PATH
    Export a transparent PNG regardless of preview background.

  --no-display
    Do not preview in the terminal; export only.

DIAGNOSTICS
  --debug
    Print generated TeX path, generated asset paths, selected chafa format,
    and keep temporary files.

  --print-tex
    Print generated .tex path.

  --show-paths
    Print generated PDF/PNG paths.

  --show-tex
    Print generated .tex content to stderr.

  --keep-temp
    Keep temporary working directory after a successful run.

  --no-keep-on-error
    Do not keep temporary working directory after errors.

  --doctor
    Check dependencies and print terminal/chafa detection information.

MISC
  -x, --examples
    Show examples.

  -h, --help
    Show this help.

EXAMPLES
  1) Simple formula, default math mode:
     texmath '\frac{a+b}{c+d}'

  2) Regression estimator:
     texmath --cols 72 '\hat{\beta}=(X^\top X)^{-1}X^\top y'

  3) aligned inside default math mode:
     texmath '
     \begin{aligned}
       \hat{\beta} &= (X^\top X)^{-1}X^\top y \\
       \hat{y} &= X\hat{\beta}
     \end{aligned}'

  4) align* as raw document body:
     texmath --raw '
     \begin{align*}
       \hat{\beta} &= (X^\top X)^{-1}X^\top y \\
       \hat{y} &= X\hat{\beta}
     \end{align*}'

  5) Operator declared in preamble:
     texmath --raw \
       --preamble '\DeclareMathOperator{\modmax}{Mod_{\max}}' \
       '\begin{align*}
          \modmax &= 10 \\
          \hat{y} &= X\hat{\beta}
        \end{align*}'

  6) Text block:
     texmath --text --cols 90 '
     En bedre idé:\\[0.35em]
     Eksponeringsreduktion + intet rigtigt user-\texttt{\$HOME}\\
     + private tilladelser (\texttt{umask 077})\\
     + ephemeral artefakter.'

  7) Export only:
     texmath --no-display --save-pdf reg.pdf \
       --save-transparent-png reg.png \
       '\hat{y}=X\hat{\beta}'

  8) Debug a failing expression:
     texmath --debug --raw '\begin{align*}x &= y\end{align*}'

INSTALLATION
  install -Dm755 texmath ~/.local/bin/texmath

  Or system-wide:

  sudo install -Dm755 texmath /usr/local/bin/texmath

EOF
}

function show_examples() {
  cat <<'EOF'
Examples:

1) Simple formula
  texmath '\frac{a+b}{c+d}'

2) Regression estimator
  texmath --cols 72 '\hat{\beta}=(X^\top X)^{-1}X^\top y'

3) aligned in default math mode
  texmath '\begin{aligned}
    \hat{\beta} &= (X^\top X)^{-1}X^\top y \\
    \hat{y} &= X\hat{\beta}
  \end{aligned}'

4) align* in raw body mode
  texmath --raw '\begin{align*}
    \hat{\beta} &= (X^\top X)^{-1}X^\top y \\
    \hat{y} &= X\hat{\beta}
  \end{align*}'

5) Operator declared in preamble
  texmath --raw \
    --preamble '\DeclareMathOperator{\modmax}{Mod_{\max}}' \
    '\begin{align*}
       \modmax &= 10 \\
       \hat{y} &= X\hat{\beta}
     \end{align*}'

6) Text block
  texmath --text --cols 90 '\textbf{En bedre idé:}\\[0.35em]
  Eksponeringsreduktion + intet rigtigt user-\texttt{\$HOME}\\
  + private tilladelser (\texttt{umask 077})\\
  + ephemeral artefakter.'

7) Transparent PNG export
  texmath --save-transparent-png gaussian.png \
    '\int_0^\infty e^{-x^2}\,dx=\frac{\sqrt{\pi}}{2}'

8) Export only
  texmath --no-display --save-pdf reg.pdf \
    --save-transparent-png reg.png \
    '\hat{y}=X\hat{\beta}'

9) Keep files and inspect generated TeX
  texmath --debug '\frac{a}{b}'

10) Watch a raw file
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
  local cmd

  for cmd in tectonic pdftocairo chafa; do
    if ! have_cmd "$cmd"; then
      missing+=("$cmd")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    printf 'Missing required command(s): %s\n' "${missing[*]}" >&2
    printf 'Install on Arch Linux with:\n' >&2
    printf '  sudo pacman -S tectonic poppler chafa\n' >&2
    exit 1
  fi
}

function print_doctor() {
  require_cmds

  printf 'texmath doctor\n'
  printf '  bash:         %s\n' "${BASH_VERSION}"
  printf '  tectonic:     %s\n' "$(tectonic --version 2>/dev/null || true)"
  printf '  pdftocairo:   %s\n' "$(pdftocairo -v 2>&1 | head -n 1)"
  printf '  chafa:        %s\n' "$(chafa --version 2>/dev/null | head -n 1)"
  printf '  TERM:         %s\n' "${TERM:-}"
  printf '  TERM_PROGRAM: %s\n' "${TERM_PROGRAM:-}"
  printf '  COLORTERM:    %s\n' "${COLORTERM:-}"
  printf '  GHOSTTY:      %s\n' "${GHOSTTY_RESOURCES_DIR:+yes}"
  printf '  KITTY:        %s\n' "${KITTY_WINDOW_ID:+yes}"
  printf '  WEZTERM:      %s\n' "${WEZTERM_EXECUTABLE:+yes}"
  printf '  format(auto): %s\n' "$(detect_chafa_format)"
}

function normalize_preset_to_rows() {
  local preset="${1,,}"

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
  local size="$1"
  local lowered="${1,,}"

  case "$lowered" in
    tiny)         printf '\\tiny\n' ;;
    scriptsize)   printf '\\scriptsize\n' ;;
    footnotesize) printf '\\footnotesize\n' ;;
    small)        printf '\\small\n' ;;
    normal)       printf '\\normalsize\n' ;;
    large)        printf '\\large\n' ;;
    huge)         printf '\\huge\n' ;;
    *)
      case "$size" in
        Large|LARGE|Huge)
          printf '\\%s\n' "$size"
          ;;
        *)
          die \
            "Invalid --font-size: $1"
          ;;
      esac
      ;;
  esac
}

function normalize_bg_mode() {
  local mode="${1,,}"

  case "$mode" in
    transparent|black|white)
      printf '%s\n' "$mode"
      ;;
    *)
      die "Invalid --bg value: $1 (use transparent, black, white)"
      ;;
  esac
}

function normalize_chafa_format() {
  local format="${1,,}"

  case "$format" in
    auto|kitty|iterm|sixels|symbols)
      printf '%s\n' "$format"
      ;;
    sixel)
      printf 'sixels\n'
      ;;
    *)
      die "Invalid --format: $1 (use auto, kitty, iterm, sixels, symbols)"
      ;;
  esac
}

function detect_chafa_format() {
  if [[ -n "${TEXMATH_CHAFA_FORMAT:-}" ]]; then
    normalize_chafa_format "$TEXMATH_CHAFA_FORMAT"
    return 0
  fi

  if [[ -n "${GHOSTTY_RESOURCES_DIR:-}" ]]; then
    printf 'kitty\n'
    return 0
  fi

  if [[ -n "${KITTY_WINDOW_ID:-}" ]]; then
    printf 'kitty\n'
    return 0
  fi

  if [[ -n "${WEZTERM_EXECUTABLE:-}" ]]; then
    printf 'kitty\n'
    return 0
  fi

  case "${TERM_PROGRAM:-}" in
    Ghostty|ghostty|WezTerm|wezterm)
      printf 'kitty\n'
      return 0
      ;;
    iTerm.app)
      printf 'iterm\n'
      return 0
      ;;
  esac

  case "${TERM:-}" in
    *kitty*|*ghostty*|*wezterm*)
      printf 'kitty\n'
      return 0
      ;;
    *sixel*|*xterm*|*foot*)
      printf 'sixels\n'
      return 0
      ;;
  esac

  printf 'symbols\n'
}

function current_terminal_cols() {
  local cols=""

  if [[ -n "${COLUMNS:-}" ]] && [[ "${COLUMNS}" =~ ^[0-9]+$ ]]; then
    cols="${COLUMNS}"
  elif have_cmd tput; then
    cols="$(tput cols 2>/dev/null || true)"
  fi

  if [[ -z "$cols" ]] || ! [[ "$cols" =~ ^[0-9]+$ ]]; then
    cols="120"
  fi

  printf '%s\n' "$cols"
}

function parse_size_argument() {
  local size_arg="$1"

  if [[ "$size_arg" =~ ^([0-9]+)[xX]([0-9]+)$ ]]; then
    printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi

  die "Invalid --size value: $size_arg (use COLSxROWS, e.g. 90x12)"
}

function ensure_parent_dir() {
  local path="$1"
  local parent

  parent="$(dirname -- "$path")"
  mkdir -p -- "$parent"
}

function editor_default_content() {
  cat <<'EOF'
\begin{align*}
\hat{\beta} &= (X^\top X)^{-1}X^\top y \\
\hat{y} &= X\hat{\beta}
\end{align*}
EOF
}

function read_input_content() {
  local input_file="$1"
  local edit_mode="$2"
  shift 2
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
    rm -f -- "$tmp_input"
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

  die "No LaTeX input provided"
}

function build_preamble_text() {
  local -n preamble_items_ref="$1"
  local -n preamble_files_ref="$2"
  local item
  local file

  for item in "${preamble_items_ref[@]}"; do
    printf '%s\n' "$item"
  done

  for file in "${preamble_files_ref[@]}"; do
    [[ -f "$file" ]] || die "Preamble file not found: $file"
    cat "$file"
    printf '\n'
  done
}

function generate_tex_file() {
  local tex_path="$1"
  local latex_body="$2"
  local mode="$3"
  local font_size_cmd="$4"
  local fg_color="$5"
  local bg_mode="$6"
  local border_pt="$7"
  local preamble_text="$8"

  {
    printf '\\documentclass[border=%spt,varwidth]{standalone}\n' "$border_pt"
    printf '\\usepackage[T1]{fontenc}\n'
    printf '\\usepackage[utf8]{inputenc}\n'
    printf '\\usepackage{lmodern}\n'
    printf '\\usepackage{amsmath,amssymb,mathtools,bm}\n'
    printf '\\usepackage{xcolor}\n'
    printf '\\usepackage{varwidth}\n'
    printf '\\usepackage{microtype}\n'
    printf '\\setlength{\\parindent}{0pt}\n'

    case "$bg_mode" in
      black)
        printf '\\pagecolor{black}\n'
        ;;
      white)
        printf '\\pagecolor{white}\n'
        ;;
    esac

    if [[ -n "$preamble_text" ]]; then
      printf '\n%% User preamble additions ------------------------------------------\n'
      printf '%s\n' "$preamble_text"
      printf '%% -----------------------------------------------------------------\n'
    fi

    printf '\n\\begin{document}\n'
    printf '{\\color{%s}%s\n' "$fg_color" "$font_size_cmd"

    case "$mode" in
      math)
        printf '\\[\n%s\n\\]\n' "$latex_body"
        ;;
      raw)
        printf '%s\n' "$latex_body"
        ;;
      text)
        printf '\\begin{varwidth}{\\linewidth}\n'
        printf '%s\n' "$latex_body"
        printf '\\end{varwidth}\n'
        ;;
      *)
        die "Internal error: invalid mode: $mode"
        ;;
    esac

    printf '}\n'
    printf '\\end{document}\n'
  } > "$tex_path"
}

function run_tectonic_compile() {
  local tex_path="$1"
  local outdir="$2"
  local stderr_path="$3"

  tectonic \
    "$tex_path" \
    --outdir "$outdir" \
    --keep-logs \
    --keep-intermediates \
    >/dev/null 2>"$stderr_path"
}

function convert_pdf_to_png() {
  local pdf_path="$1"
  local png_base="$2"
  local png_path="$3"
  local dpi="$4"
  local transparent="$5"
  local stderr_path="$6"

  local args=(-png -singlefile -r "$dpi")

  if [[ "$transparent" == "true" ]]; then
    args+=(-transp)
  fi

  if ! pdftocairo \
    "${args[@]}" \
    "$pdf_path" \
    "$png_base" \
    >/dev/null 2>"$stderr_path"; then
    cat "$stderr_path" >&2
    printf 'Error: pdftocairo failed.\n' >&2
    return 1
  fi

  [[ -f "$png_path" ]] || {
    printf 'Error: expected PNG was not created: %s\n' "$png_path" >&2
    return 1
  }
}

function build_render_assets() {
  local tmpdir="$1"
  local stem="$2"
  local latex_body="$3"
  local mode="$4"
  local font_size_cmd="$5"
  local fg_color="$6"
  local bg_mode="$7"
  local border_pt="$8"
  local dpi="$9"
  local preamble_text="${10}"
  local show_tex="${11}"

  local tex_path="${tmpdir}/${stem}.tex"
  local pdf_path="${tmpdir}/${stem}.pdf"
  local png_base="${tmpdir}/${stem}"
  local png_path="${tmpdir}/${stem}.png"
  local tectonic_stderr="${tmpdir}/${stem}.tectonic.stderr"
  local cairo_stderr="${tmpdir}/${stem}.pdftocairo.stderr"
  local transparent="false"

  generate_tex_file \
    "$tex_path" \
    "$latex_body" \
    "$mode" \
    "$font_size_cmd" \
    "$fg_color" \
    "$bg_mode" \
    "$border_pt" \
    "$preamble_text"

  if [[ "$show_tex" == "true" ]]; then
    printf '\n--- Generated TeX: %s ---\n' "$tex_path" >&2
    sed -n '1,220p' "$tex_path" >&2
    printf '%s\n' '--- End generated TeX ---' >&2
  fi

  if ! run_tectonic_compile "$tex_path" "$tmpdir" "$tectonic_stderr"; then
    cat "$tectonic_stderr" >&2
    printf '\nGenerated TeX kept at: %s\n' "$tex_path" >&2
    return 1
  fi

  [[ -f "$pdf_path" ]] || {
    printf 'Error: expected PDF was not created: %s\n' "$pdf_path" >&2
    printf 'Generated TeX kept at: %s\n' "$tex_path" >&2
    return 1
  }

  if [[ "$bg_mode" == "transparent" ]]; then
    transparent="true"
  fi

  convert_pdf_to_png \
    "$pdf_path" \
    "$png_base" \
    "$png_path" \
    "$dpi" \
    "$transparent" \
    "$cairo_stderr"
}

function display_png() {
  local png_path="$1"
  local chafa_format="$2"
  local optimize="$3"
  local preview_cols="$4"
  local rows="$5"

  local args=(-O "$optimize" --size="${preview_cols}x${rows}")

  if [[ "$chafa_format" != "auto" ]]; then
    args=(-f "$chafa_format" "${args[@]}")
  fi

  chafa "${args[@]}" "$png_path"
}

function render_once() {
  local latex_body="$1"
  local mode="$2"
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
  local keep_on_error="${17}"
  local print_tex="${18}"
  local show_paths="${19}"
  local show_tex="${20}"
  local debug_mode="${21}"
  local preamble_text="${22}"

  local tmpdir
  local main_tex_path
  local main_pdf_path
  local main_png_path
  local preview_cols
  local actual_format

  tmpdir="$(mktemp -d)"
  main_tex_path="${tmpdir}/formula.tex"
  main_pdf_path="${tmpdir}/formula.pdf"
  main_png_path="${tmpdir}/formula.png"

  if [[ "$chafa_format" == "auto" ]]; then
    actual_format="$(detect_chafa_format)"
  else
    actual_format="$chafa_format"
  fi

  if [[ "$debug_mode" == "true" ]]; then
    printf 'texmath debug\n' >&2
    printf '  tmpdir:       %s\n' "$tmpdir" >&2
    printf '  mode:         %s\n' "$mode" >&2
    printf '  chafa format: %s\n' "$actual_format" >&2
    printf '  bg:           %s\n' "$bg_mode" >&2
    printf '  fg:           %s\n' "$fg_color" >&2
  fi

  if ! build_render_assets \
    "$tmpdir" \
    "formula" \
    "$latex_body" \
    "$mode" \
    "$font_size_cmd" \
    "$fg_color" \
    "$bg_mode" \
    "$border_pt" \
    "$dpi" \
    "$preamble_text" \
    "$show_tex"; then
    if [[ "$keep_on_error" == "true" ]]; then
      printf 'Temporary directory kept after error: %s\n' "$tmpdir" >&2
    else
      rm -rf -- "$tmpdir"
    fi
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

    display_png \
      "$main_png_path" \
      "$actual_format" \
      "$optimize" \
      "$preview_cols" \
      "$rows"
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
        "$mode" \
        "$font_size_cmd" \
        "$fg_color" \
        "transparent" \
        "$border_pt" \
        "$dpi" \
        "$preamble_text" \
        "$show_tex"; then
        if [[ "$keep_on_error" == "true" ]]; then
          printf 'Temporary directory kept after error: %s\n' "$tmpdir" >&2
        else
          rm -rf -- "$tmpdir"
        fi
        return 1
      fi

      ensure_parent_dir "$save_transparent_png"
      cp -f -- "${tmpdir}/formula_transparent.png" "$save_transparent_png"
    fi
  fi

  if [[ "$show_paths" == "true" ]]; then
    printf '\nGenerated assets:\n' >&2
    printf '  TeX: %s\n' "$main_tex_path" >&2
    printf '  PDF: %s\n' "$main_pdf_path" >&2
    printf '  PNG: %s\n' "$main_png_path" >&2
  fi

  if [[ "$keep_temp" == "true" ]]; then
    printf '\nTemporary directory kept: %s\n' "$tmpdir" >&2
  else
    rm -rf -- "$tmpdir"
  fi
}

function clear_screen_soft() {
  printf '\033[2J\033[H'
}

function watch_loop() {
  local input_file="$1"
  shift

  local prev_hash=""
  local current_content=""
  local current_hash=""

  while true; do
    current_content="$(cat "$input_file")"
    current_hash="$(printf '%s' "$current_content" | sha256sum | awk '{print $1}')"

    if [[ "$current_hash" != "$prev_hash" ]]; then
      clear_screen_soft
      render_once "$current_content" "$@"
      prev_hash="$current_hash"
    fi

    sleep 0.6
  done
}

function main() {
  local mode="math"
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
  local chafa_format="auto"
  local optimize="5"
  local save_pdf=""
  local save_png=""
  local save_transparent_png=""
  local no_display="false"
  local keep_temp="false"
  local keep_on_error="true"
  local print_tex="false"
  local show_paths="false"
  local show_tex="false"
  local debug_mode="false"

  local args=()
  local preamble_items=()
  local preamble_files=()
  local preamble_text
  local font_size_cmd
  local opt

  require_cmds

  while (( $# > 0 )); do
    opt="${1,,}"

    case "$opt" in
      -h|--help)
        show_help
        exit 0
        ;;
      -x|--examples)
        show_examples
        exit 0
        ;;
      --doctor)
        print_doctor
        exit 0
        ;;
      -r|--raw|--body)
        mode="raw"
        shift
        ;;
      -t|--text)
        mode="text"
        shift
        ;;
      --math)
        mode="math"
        shift
        ;;
      -e|--edit)
        edit_mode="true"
        mode="raw"
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
      --preamble)
        [[ $# -ge 2 ]] || die "--preamble requires LaTeX content"
        preamble_items+=("$2")
        shift 2
        ;;
      --preamble-file)
        [[ $# -ge 2 ]] || die "--preamble-file requires a path"
        preamble_files+=("$2")
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
        bg_mode="$(normalize_bg_mode "$2")"
        shift 2
        ;;
      --border)
        [[ $# -ge 2 ]] || die "--border requires a value"
        border_pt="$2"
        shift 2
        ;;
      --format)
        [[ $# -ge 2 ]] || die "--format requires a value"
        chafa_format="$(normalize_chafa_format "$2")"
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
      --no-keep-on-error)
        keep_on_error="false"
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
      --show-tex)
        show_tex="true"
        shift
        ;;
      --debug)
        debug_mode="true"
        keep_temp="true"
        print_tex="true"
        show_paths="true"
        show_tex="true"
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

  font_size_cmd="$(normalize_font_size "$font_size")"
  preamble_text="$(build_preamble_text preamble_items preamble_files)"

  if [[ "$watch_mode" == "true" ]]; then
    [[ -n "$input_file" ]] || die "--watch requires --file"
    [[ "$edit_mode" != "true" ]] || die "--watch does not pair with --edit"

    watch_loop \
      "$input_file" \
      "$mode" \
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
      "$keep_on_error" \
      "$print_tex" \
      "$show_paths" \
      "$show_tex" \
      "$debug_mode" \
      "$preamble_text"
    exit 0
  fi

  local latex_body
  latex_body="$(
    read_input_content "$input_file" "$edit_mode" "${args[@]}"
  )"

  render_once \
    "$latex_body" \
    "$mode" \
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
    "$keep_on_error" \
    "$print_tex" \
    "$show_paths" \
    "$show_tex" \
    "$debug_mode" \
    "$preamble_text"
}

main "$@"
