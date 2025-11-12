#!/usr/bin/env bash
# codefmt — enforce a max line width (default 81) for Python and shell scripts
# Version: 0.4.0  |  License: MIT  |  Author: ChatGPT (adapted for Heini W. Johnsen)
#
# Overview
#   • Detects language (Python vs. shell) by extension or shebang.
#   • Python → prefers Black (safe structural rewriter). Falls back to wrapping
#     comments/docstrings only (never alters Python code tokens) if Black is missing.
#   • Shell  → uses shfmt (indent/cleanup). Additionally performs a conservative
#     long‑line reflow that only splits at shell control operators (&&, ||, |, |&, ;)
#     outside quotes and heredocs. Trailing comments are wrapped separately.
#   • Indentation for shell continuations uses 2 spaces (configurable).
#
#   This is intentionally cautious: it will *not* invent line continuations in
#   arbitrary places. If no safe split point is found, the line is left as‑is and
#   you get a warning.
#
# Exit codes:
#   0 ok, 1 usage, 2 deps missing (and not installed), 3 runtime error

set -Eeuo pipefail

# ─────────────────────────────── User‑tunable defaults ──────────────────────────────
WIDTH_DEFAULT=81
SHELL_INDENT_DEFAULT=2
VERBOSE=0
DRY_RUN=0
AUTO_INSTALL=0

# Preferred bat options (fallback to cat)

# From here down is your normal script. Example: a help function that uses helpout.
function print_help() {
local prog
prog=$(basename "$0")
  # Pipes the here-doc into helpout (bat when available; cat otherwise).
  if command -v helpout >/dev/null 2>&1; then
    helpout <<'EOF'
codefmt — enforce a max column width on Python & shell scripts

USAGE
  codefmt [OPTIONS] <files...>

OPTIONS
  -w, --width N          Max columns (default: 81)
  -i, --indent N         Continuation indent for shell (spaces; default: 2)
  -n, --dry-run          Do not modify files; print unified diff instead
  -a, --auto-install     Attempt to install missing formatters (Black, shfmt)
  -v, --verbose          Verbose logging
  -h, --help             Show this help

BEHAVIOR
  • Python: If available, runs: black --line-length <N> <file>
            Fallback: wrap only comments/docstrings (code left untouched)
  • Shell:  First runs shfmt (-i <N> -ci -bn -sr). Then reflows long lines by
            splitting only at safe control operators: '&&', '||', '|', '|&', ';'
            outside quotes/heredocs. Trailing comments are wrapped separately.

SAFETY
  • No formatter can guarantee zero risk. Commit before mass changes.
  • Lines without safe split points are left unchanged and reported.

EXAMPLES
  codefmt script.sh analysis.py
  codefmt -w 81 -i 2 -- analysis.sh
EOF
 else
    # Absolute last-resort fallback:
    cat <<'EOF'
schedule_power — Countdown to reboot/shutdown
Usage: schedule_power -r|-s [-H H] [-M M] [-S S] [options]
  -r, -s                Reboot or shutdown
  -H, -M, -S            Delay components (non-negative integers)
  -h, --help            Show this help and exit
Silencing:
  --silence, --silence-warnings, --silence=alarm
  --silence=output, --silence=all, --quiet
Cancel:
  --cancel, --cancel-hint STR
Notes:
  Final 10s warning is always shown. Uses systemd-inhibit by default.
EOF
  fi
}

log() { (( VERBOSE )) && printf 'codefmt: %s\n' "$*" >&2; }
warn() { printf 'codefmt: WARNING: %s\n' "$*" >&2; }
err()  { printf 'codefmt: ERROR: %s\n' "$*" >&2; }

# ─────────────────────────────── Utility helpers ────────────────────────────────────
abspath() { python3 - "$1" <<'PY'
import os,sys
p=sys.argv[1]
print(os.path.abspath(p))
PY
}

detect_lang() {
  # echo "python" | "shell" | "unknown"
  local f="$1" first
  if [[ "$f" =~ \.py$ ]]; then echo python; return; fi
  if [[ "$f" =~ \.(sh|bash|zsh)$ ]]; then echo shell; return; fi
  if read -r first <"$f" && [[ $first == "#!"* ]]; then
    if grep -Eq 'python(3)?(\s|$)' <<<"$first"; then echo python; return; fi
    if grep -Eq '(bash|sh|zsh)(\s|$)'  <<<"$first"; then echo shell; return; fi
  fi
  echo unknown
}

require_cmd() {
  local cmd="$1" label="${2:-$1}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    if (( AUTO_INSTALL )); then
      log "Installing missing dependency: $label"
      if command -v pacman >/dev/null 2>&1; then
        case "$cmd" in
          black) sudo pacman -S --needed --noconfirm python-black >/dev/null ;;
          shfmt) sudo pacman -S --needed --noconfirm shfmt >/dev/null ;;
          *)     err "No installer rule for '$cmd'"; return 2 ;;
        esac
      elif command -v pipx >/dev/null 2>&1; then
        case "$cmd" in
          black) pipx install black >/dev/null ;;
          shfmt) err "Please install 'shfmt' via your package manager (Go tool)"; return 2 ;;
        esac
      else
        err "Cannot auto-install '$label' (no pacman/pipx)."; return 2
      fi
    else
      return 2
    fi
  fi
}

mktempf() { mktemp "${TMPDIR:-/tmp}/codefmt.XXXXXX"; }
run_diff_or_replace() {
  local src="$1" tmp="$2"
  if (( DRY_RUN )); then
    if command -v diff >/dev/null 2>&1; then
      diff -u --label "$src" --label "$src (reflowed)" "$src" "$tmp" || true
    else
      cat "$tmp"
    fi
  else
    mv -f "$tmp" "$src"
  fi
}

# ───────────────────────────── Python formatters ───────────────────────────────────
python_fallback_wrap() {
  # Wrap only comments and docstrings to WIDTH; do not touch code tokens.
  local file="$1" width="$2" tmp
  tmp=$(mktempf)
  python3 - "$file" "$width" >"$tmp" <<'PY'
import io, sys, textwrap, tokenize
from io import StringIO

path = sys.argv[1]
width = int(sys.argv[2])

with open(path, 'r', encoding='utf-8') as f:
    src = f.read()

out = io.StringIO()

def wrap_comment(line, indent, marker):
    prefix = indent + marker + ('' if marker.endswith(' ') else ' ')
    body = line[len(indent) + len(marker):].lstrip()
    wrapped = textwrap.fill(body, width=width, subsequent_indent=prefix, initial_indent=prefix, break_long_words=False, break_on_hyphens=False)
    return wrapped + '\n'

# Heuristic docstring wrapper: only if a triple-quoted block is a standalone stmt
lines = src.splitlines(True)
i = 0
while i < len(lines):
    line = lines[i]
    stripped = line.lstrip()
    indent = line[:len(line)-len(stripped)]
    if stripped.startswith('#'):
        # full-line comment
        marker = '#'
        out.write(wrap_comment(line, indent, marker))
        i += 1
        continue
    # Try to detect a docstring line that begins with triple quotes
    if stripped.startswith(('"""', "'''")):
        quote = '"""' if stripped.startswith('"""') else "'''"
        block = [line]
        i += 1
        # accumulate until closing on its own line
        while i < len(lines):
            block.append(lines[i])
            if lines[i].strip().endswith(quote):
                i += 1
                break
            i += 1
        body = ''.join(block)
        # Only wrap the interior text, keep quotes
        head_idx = body.find(quote) + len(quote)
        tail_idx = body.rfind(quote)
        if 0 <= head_idx <= tail_idx:
            inner = body[head_idx:tail_idx]
            # normalize leading newlines for clean wrapping
            inner_stripped = inner.strip('\n')
            wrapped = textwrap.fill(
                inner_stripped,
                width=width,
                subsequent_indent=indent,
                initial_indent=indent,
                break_long_words=False,
                break_on_hyphens=False,
            )
            new = body[:head_idx] + '\n' + wrapped + '\n' + body[tail_idx:]
            out.write(new)
        else:
            out.write(body)
        continue
    # default passthrough
    out.write(line)
    i += 1

sys.stdout.write(out.getvalue())
PY
  run_diff_or_replace "$file" "$tmp"
}

python_format() {
  local file="$1" width="$2"
  if require_cmd black Black; then
    log "Python: black -q -l $width $file"
    if (( DRY_RUN )); then
      black -l "$width" --diff "$file" | bat_or_cat
    else
      black -q -l "$width" "$file"
    fi
  else
    warn "'black' not available; falling back to wrapping comments/docstrings only."
    python_fallback_wrap "$file" "$width"
  fi
}

# ───────────────────────────── Shell reflow (quote‑aware) ──────────────────────────
shell_pretty() {
  local file="$1" indent="$2"
  if require_cmd shfmt shfmt; then
    log "Shell: shfmt -w -i $indent -ci -bn -sr $file"
    if (( DRY_RUN )); then
      shfmt -i "$indent" -ci -bn -sr "$file" | diff -u "$file" - || true
    else
      shfmt -w -i "$indent" -ci -bn -sr "$file"
    fi
  else
    warn "'shfmt' not available; skipping indentation cleanup."
  fi
}

shell_wrap_long_lines() {
  local file="$1" width="$2" indent_cont="$3" tmp
  tmp=$(mktempf)
  python3 - "$file" "$width" "$indent_cont" >"$tmp" <<'PY'
import sys, re, textwrap
path, width, cont = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])

with open(path, 'r', encoding='utf-8') as f:
    lines = f.read().splitlines(True)

out = []
heredoc_end = None
heredoc_strip = False

# Helper: find start of unquoted comment '#'
def split_trailing_comment(s):
    q = None
    esc = False
    for i, ch in enumerate(s):
        if esc:
            esc = False
            continue
        if ch == '\\':
            esc = True
            continue
        if q:
            if (ch == q):
                q = None
            continue
        else:
            if ch in ('"', "'", '`'):
                q = ch
                continue
            if ch == '#':
                return s[:i], s[i:]
    return s, ''

# Find last safe split before limit at control operators
TOKENS = ['&&', '||', '|&', '|', ';']

def last_safe_break(s, limit):
    q = None
    esc = False
    last = None
    i = 0
    while i < len(s):
        ch = s[i]
        if esc:
            esc = False
            i += 1
            continue
        if ch == '\\':
            esc = True
            i += 1
            continue
        if q:
            if ch == q:
                q = None
            i += 1
            continue
        else:
            if ch in ('"', "'", '`'):
                q = ch
                i += 1
                continue
            # comment begins, stop scanning
            if ch == '#':
                break
            for tok in TOKENS:
                L = len(tok)
                if s.startswith(tok, i):
                    end = i + L
                    if end <= limit:
                        last = end

        i += 1
        if i > limit and (last is not None):
            break
    return last

for raw in lines:
    line = raw
    # heredoc handling
    if heredoc_end is not None:
        out.append(line)
        if (line.strip() == heredoc_end) or (heredoc_strip and line.lstrip().strip() == heredoc_end):
            heredoc_end = None
            heredoc_strip = False
        continue

    # detect heredoc start
    m = re.search(r"<<-?\s*([A-Za-z0-9_]+)", line)
    if m:
        heredoc_end = m.group(1)
        heredoc_strip = ('<<-' in line)
        out.append(line)
        continue

    # preserve very short or blank lines
    if len(line.rstrip('\n')) <= width:
        out.append(line)
        continue

    # split trailing comment if any
    code, comment = split_trailing_comment(line.rstrip('\n'))

    # reflow the comment separately
    comment_out = ''
    if comment:
        # keep one space after '#'
        prefix = ''
        # figure existing indent
        indent = len(code) - len(code.lstrip(' '))
        cprefix = ' ' * indent + '# '
        body = comment.lstrip('#').lstrip()
        comment_out = '\n'.join(textwrap.wrap(body, width=width, initial_indent=cprefix, subsequent_indent=cprefix, break_long_words=False, break_on_hyphens=False))

    # Iteratively break long code lines at safe operators
    current = code
    first_indent = len(current) - len(current.lstrip(' '))
    cont_indent = ' ' * (first_indent + cont)

    while len(current) > width:
        idx = last_safe_break(current, width)
        if idx is None or idx <= 0:
            # give up, keep as-is
            break
        head = current[:idx].rstrip()
        tail = current[idx:].lstrip()
        out.append(head + '\n')
        current = cont_indent + tail
    out.append(current + ('\n' if not current.endswith('\n') else ''))

    if comment_out:
        out.append(comment_out + '\n')

sys.stdout.write(''.join(out))
PY
  run_diff_or_replace "$file" "$tmp"
}

shell_format() {
  local file="$1" width="$2" indent="$3"
  shell_pretty "$file" "$indent"
  shell_wrap_long_lines "$file" "$width" "$indent"
}

# ───────────────────────────── Argument parsing ─────────────────────────────────────
WIDTH="$WIDTH_DEFAULT"
SHELL_INDENT="$SHELL_INDENT_DEFAULT"

FILES=()
while (( $# )); do
  case "$1" in
    -w|--width) WIDTH="$2"; shift 2;;
    -i|--indent) SHELL_INDENT="$2"; shift 2;;
    -n|--dry-run) DRY_RUN=1; shift;;
    -a|--auto-install) AUTO_INSTALL=1; shift;;
    -v|--verbose) VERBOSE=$((VERBOSE+1)); shift;;
    -h|--help) print_help; exit 0;;
    --) shift; while (( $# )); do FILES+=("$1"); shift; done; break;;
    -*) err "Unknown option: $1"; print_help; exit 1;;
    *) FILES+=("$1"); shift;;
  esac
done

(( ${#FILES[@]} )) || { print_help; exit 1; }

# ───────────────────────────── Main loop ───────────────────────────────────────────
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || { err "Not a file: $f"; exit 3; }
  lang=$(detect_lang "$f")
  case "$lang" in
    python)
      log "Formatting (python): $(abspath "$f")"
      python_forma
