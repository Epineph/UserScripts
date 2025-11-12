#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# helpout.sh — portable help/preview dispatcher with optional 'bat' styling
# ──────────────────────────────────────────────────────────────────────────────
# Environment knobs (set these in ~/.zshrc; not hard-coded in scripts):
#   HELPOUT_ENABLE_BAT   : 1 to prefer bat if present (default 1)
#   HELPOUT_BAT_BIN      : 'bat' or 'batcat' (auto-detected if unset)
#   HELPOUT_BAT_OPTS     : extra bat options, e.g.:
#     --style="grid,header,snip" --italic-text="always" --squeeze-blank \
#     --squeeze-limit="2" --force-colorization --terminal-width="auto" \
#     --tabs="2" --paging="never" --chop-long-lines
#   HELP_PAGER           : e.g., "less -R" (fallbacks: less -R → cat)
#
# Usage in scripts:
#   cat <<'EOF' | helpout -l md -t "mytool — help"
#   # Title
#   body...
#   EOF
#   # or: helpout -l md -t "Title" /path/to/file.md
# ──────────────────────────────────────────────────────────────────────────────

# shellcheck shell=bash

function helpout() {
  local title="" lang="" force_no_bat=0 pager_override=""
  local file="-"

  # ---------------------- Parse flags ----------------------------------------
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--title)
        [[ $# -ge 2 ]] || { echo "helpout: missing title" >&2; return 2; }
        title="$2"; shift 2 ;;
      -l|--lang)
        [[ $# -ge 2 ]] || { echo "helpout: missing language" >&2; return 2; }
        lang="$2"; shift 2 ;;
      -n|--no-bat) force_no_bat=1; shift ;;
      -p|--pager)
        [[ $# -ge 2 ]] || { echo "helpout: missing pager" >&2; return 2; }
        pager_override="$2"; shift 2 ;;
      -h|--help)
        cat <<'EOH'
helpout — portable help viewer

Options:
  -t, --title  <str>   Decorative file-name/title when using bat.
  -l, --lang   <lang>  Syntax hint (e.g., md, txt, sh, python).
  -n, --no-bat         Force pager fallback, do not use bat.
  -p, --pager  <cmd>   Override HELP_PAGER (e.g., "less -R", "cat").
  -h, --help           Show this message.

Input:
  Reads from stdin by default. Provide a file path as the last argument
  to render that file instead (e.g., helpout -l md README.md).
EOH
        return 0 ;;
      --) shift; break ;;
      *)  break ;;
    esac
  done

  # Optional file argument.
  if [[ $# -gt 0 ]]; then
    file="$1"
  fi

  # ---------------------- Decide viewer --------------------------------------
  local pager="${pager_override:-${HELP_PAGER:-}}"
  local use_bat=0 batbin=""

  if (( force_no_bat == 0 )); then
    if [[ "${HELPOUT_ENABLE_BAT:-1}" -eq 1 ]]; then
      # Resolve bat binary.
      if [[ -n "${HELPOUT_BAT_BIN:-}" ]] && command -v "$HELPOUT_BAT_BIN" \
           >/dev/null 2>&1; then
        batbin="$HELPOUT_BAT_BIN"
      elif command -v bat >/dev/null 2>&1; then
        batbin="bat"
      elif command -v batcat >/dev/null 2>&1; then
        batbin="batcat"
      fi
      [[ -n "$batbin" ]] && use_bat=1
    fi
  fi

  # ---------------------- Render with bat if enabled -------------------------
  if (( use_bat == 1 )); then
    # Build bat option array safely. Word-splitting is intentional here to
    # allow users to provide quoted values inside HELPOUT_BAT_OPTS.
    local -a _bat_opts
    if [[ -n "${HELPOUT_BAT_OPTS:-}" ]]; then
      # shellcheck disable=SC2206
      _bat_opts=("${=HELPOUT_BAT_OPTS}")
    else
      # Minimal sane defaults; tune in ~/.zshrc via HELPOUT_BAT_OPTS.
      _bat_opts=(--style=plain --paging=never)
    fi
    [[ -n "$lang"  ]]  && _bat_opts+=(--language "$lang")
    [[ -n "$title" ]]  && _bat_opts+=(--file-name "$title")

    if [[ "$file" == "-" ]]; then
      "$batbin" "${_bat_opts[@]}" -
    else
      "$batbin" "${_bat_opts[@]}" "$file"
    fi
    return $?
  fi

  # ---------------------- Fallback pager -------------------------------------
  if [[ -z "$pager" ]]; then
    if command -v less >/dev/null 2>&1; then
      pager="less -R"
    else
      pager="cat"
    fi
  fi

  if [[ "$file" == "-" ]]; then
    "${=pager}"
  else
    "${=pager}" <"$file"
  fi
}
# ──────────────────────────────────────────────────────────────────────────────
