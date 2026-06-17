#!/usr/bin/env bash
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# mdview
#
# Unified Markdown viewer/exporter.
#
# Modes:
#   auto    terminal preview: glow -> mdcat -> rich -> bat -> cat
#   glow    force glow
#   mdcat   force mdcat
#   rich    force rich-cli
#   source  source view through bat/cat
#   html    render standalone HTML through pandoc and open it
#   serve   serve through grip, falling back to pandoc + python http.server
#   epub    create .epub through pandoc
# -----------------------------------------------------------------------------

: "${HELP_PAGER:=cat}"
: "${BROWSER:=}"

MODE="auto"
INPUT=""
OUTPUT=""
TITLE=""
AUTHOR=""
COVER=""
CSS=""
PORT="6419"
OPEN_OUTPUT=1
OFFLINE=0

CACHE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/mdview"

function lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

function have() {
  command -v "$1" >/dev/null 2>&1
}

function die() {
  printf 'mdview: %s\n' "$*" >&2
  exit 1
}

function page_markdown() {
  if have bat; then
    bat --style="grid,header,snip" \
      --italic-text="always" \
      --theme="gruvbox-dark" \
      --squeeze-blank \
      --squeeze-limit="2" \
      --force-colorization \
      --terminal-width="auto" \
      --tabs="2" \
      --paging="never" \
      --chop-long-lines \
      --language=markdown
  else
    cat
  fi
}

function show_help() {
  page_markdown <<'HELP_EOF'
# mdview

Unified Markdown preview and export helper.

## Usage

```bash
mdview [mode/options] FILE.md
```

## Modes

```bash
mdview FILE.md
mdview --glow FILE.md
mdview --mdcat FILE.md
mdview --rich FILE.md
mdview --source FILE.md
mdview --html FILE.md
mdview --serve FILE.md
mdview --epub FILE.md
```

## Options

```text
-h, --help              Show help
--tools                 Show detected helper tools

-m, --mode MODE         auto, glow, mdcat, rich, source, html, serve, epub
--terminal, --term      Same as --mode auto
--glow                  Same as --mode glow
--mdcat                 Same as --mode mdcat
--rich                  Same as --mode rich
--source, --bat         Show Markdown source, preferably with bat
--html                  Render standalone HTML with pandoc
--serve                 Serve preview locally
--epub                  Build EPUB with pandoc

-o, --output FILE       Output file for HTML or EPUB
--title TEXT            EPUB/HTML metadata title
--author TEXT           EPUB metadata author
--cover FILE            EPUB cover image
--css FILE              CSS for HTML/EPUB output
-b, --browser CMD       Browser command, e.g. firefox, chromium, brave
-p, --port PORT         Port for --serve mode
--offline               Avoid grip; use pandoc + python server fallback
--no-open               Do not open browser automatically
```

## Examples

```bash
mdview README.md
mdview --glow README.md
mdview --source notes.md
mdview --html notes.md
mdview --html notes.md --browser firefox
mdview --serve README.md --port 6420
mdview --serve README.md --offline
mdview --epub notes.md
mdview --epub notes.md -o notes.epub --title "My Notes"
mdview --epub book.md --title "Book" --author "Heini Winther Johnsen"
mdview --epub book.md --cover cover.jpg --css epub.css
```

## Recommended tools

```bash
sudo pacman -S bat glow pandoc python-pipx
cargo install mdcat
pipx install grip rich-cli
```
HELP_EOF
}

function show_tools() {
  local cmd

  for cmd in bat glow mdcat mdless rich pandoc grip python3 xdg-open; do
    if have "$cmd"; then
      printf '%-10s %s\n' "$cmd" "$(command -v "$cmd")"
    else
      printf '%-10s %s\n' "$cmd" "missing"
    fi
  done
}

function ensure_input_file() {
  [[ -n "$INPUT" ]] || die "No Markdown file given."
  [[ -f "$INPUT" ]] || die "Not a file: $INPUT"
}

function open_path_or_uri() {
  local target="$1"

  if [[ "$OPEN_OUTPUT" -ne 1 ]]; then
    printf '%s\n' "$target"
    return 0
  fi

  if [[ -n "$BROWSER" ]] && have "$BROWSER"; then
    "$BROWSER" "$target" >/dev/null 2>&1 &
  elif have xdg-open; then
    xdg-open "$target" >/dev/null 2>&1 &
  else
    printf '%s\n' "$target"
  fi
}

function bat_source() {
  if have bat; then
    bat --style="grid,header,snip" \
      --italic-text="always" \
      --theme="gruvbox-dark" \
      --squeeze-blank \
      --squeeze-limit="2" \
      --force-colorization \
      --terminal-width="auto" \
      --tabs="2" \
      --paging="never" \
      --chop-long-lines \
      "$INPUT"
  else
    cat "$INPUT"
  fi
}

function terminal_auto() {
  if have glow; then
    glow -p "$INPUT"
  elif have mdcat; then
    mdcat "$INPUT"
  elif have rich; then
    rich "$INPUT"
  else
    bat_source
  fi
}

function render_html_to() {
  local html="$1"
  local input_dir
  local -a args

  input_dir="$(cd -- "$(dirname -- "$INPUT")" && pwd -P)"

  args=(
    "$INPUT"
    "--from=markdown+tex_math_dollars+pipe_tables+footnotes+yaml_metadata_block"
    "--standalone"
    "--toc"
    "--mathml"
    "--resource-path=${input_dir}:."
    "-o" "$html"
  )

  [[ -n "$TITLE" ]] && args+=(--metadata "title=${TITLE}")
  [[ -n "$CSS" ]] && args+=(--css "$CSS")

  pandoc "${args[@]}"
}

function render_html() {
  have pandoc || die "pandoc is required for --html."

  mkdir -p "$CACHE_DIR"

  local html

  if [[ -n "$OUTPUT" ]]; then
    html="$OUTPUT"
  else
    html="${CACHE_DIR}/$(basename "${INPUT%.*}").html"
  fi

  render_html_to "$html"
  open_path_or_uri "$html"
}

function serve_markdown() {
  mkdir -p "$CACHE_DIR"

  if have grip && [[ "$OFFLINE" -eq 0 ]]; then
    if [[ "$OPEN_OUTPUT" -eq 1 ]]; then
      grip "$INPUT" "127.0.0.1:${PORT}" -b
    else
      grip "$INPUT" "127.0.0.1:${PORT}"
    fi
    return 0
  fi

  have pandoc || die "pandoc is required for offline --serve fallback."
  have python3 || die "python3 is required for offline --serve fallback."

  local serve_dir
  local html
  local uri

  serve_dir="${CACHE_DIR}/serve"
  html="${serve_dir}/index.html"
  uri="http://127.0.0.1:${PORT}/index.html"

  mkdir -p "$serve_dir"
  render_html_to "$html"
  open_path_or_uri "$uri"

  printf 'Serving %s\n' "$uri"
  printf 'Press Ctrl-C to stop.\n'

  python3 -m http.server "$PORT" \
    --bind 127.0.0.1 \
    --directory "$serve_dir"
}

function render_epub() {
  have pandoc || die "pandoc is required for --epub."

  local input_dir
  local output
  local -a args

  input_dir="$(cd -- "$(dirname -- "$INPUT")" && pwd -P)"
  output="${OUTPUT:-${INPUT%.*}.epub}"

  args=(
    "$INPUT"
    "--from=markdown+tex_math_dollars+pipe_tables+footnotes+yaml_metadata_block"
    "--standalone"
    "--toc"
    "--resource-path=${input_dir}:."
    "-o" "$output"
  )

  [[ -n "$TITLE" ]] && args+=(--metadata "title=${TITLE}")
  [[ -n "$AUTHOR" ]] && args+=(--metadata "author=${AUTHOR}")
  [[ -n "$COVER" ]] && args+=(--epub-cover-image "$COVER")
  [[ -n "$CSS" ]] && args+=(--css "$CSS")

  pandoc "${args[@]}"
  printf 'Wrote: %s\n' "$output"
}

while (($#)); do
  raw="$1"
  opt="$(lower "$raw")"

  case "$opt" in
    -h|--help)
      show_help
      exit 0
      ;;
    --tools)
      show_tools
      exit 0
      ;;
    -m|--mode)
      shift
      [[ $# -gt 0 ]] || die "--mode requires an argument."
      MODE="$(lower "$1")"
      ;;
    --terminal|--term|--tui)
      MODE="auto"
      ;;
    --glow)
      MODE="glow"
      ;;
    --mdcat|--mdless)
      MODE="mdcat"
      ;;
    --rich)
      MODE="rich"
      ;;
    --source|--bat)
      MODE="source"
      ;;
    --html)
      MODE="html"
      ;;
    --serve)
      MODE="serve"
      ;;
    --epub)
      MODE="epub"
      ;;
    -o|--output)
      shift
      [[ $# -gt 0 ]] || die "--output requires a file."
      OUTPUT="$1"
      ;;
    --title)
      shift
      [[ $# -gt 0 ]] || die "--title requires text."
      TITLE="$1"
      ;;
    --author)
      shift
      [[ $# -gt 0 ]] || die "--author requires text."
      AUTHOR="$1"
      ;;
    --cover)
      shift
      [[ $# -gt 0 ]] || die "--cover requires a file."
      COVER="$1"
      ;;
    --css)
      shift
      [[ $# -gt 0 ]] || die "--css requires a file."
      CSS="$1"
      ;;
    -b|--browser)
      shift
      [[ $# -gt 0 ]] || die "--browser requires a command."
      BROWSER="$1"
      ;;
    -p|--port)
      shift
      [[ $# -gt 0 ]] || die "--port requires a port number."
      PORT="$1"
      ;;
    --offline)
      OFFLINE=1
      ;;
    --no-open)
      OPEN_OUTPUT=0
      ;;
    -* )
      die "Unknown option: $raw"
      ;;
    *)
      [[ -z "$INPUT" ]] || die "Unexpected extra argument: $raw"
      INPUT="$raw"
      ;;
  esac

  shift
done

ensure_input_file

case "$MODE" in
  auto)
    terminal_auto
    ;;
  glow)
    have glow || die "glow is not installed."
    glow -p "$INPUT"
    ;;
  mdcat)
    have mdcat || die "mdcat is not installed."
    mdcat "$INPUT"
    ;;
  rich)
    have rich || die "rich-cli is not installed."
    rich "$INPUT"
    ;;
  source)
    bat_source
    ;;
  html)
    render_html
    ;;
  serve)
    serve_markdown
    ;;
  epub)
    render_epub
    ;;
  *)
    die "Unknown mode: $MODE"
    ;;
esac
