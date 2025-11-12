#!/usr/bin/env bash
###############################################################################
#  bat-view
#
#  Purpose  : Provide a convenient front-end to `bat` that bakes-in your
#             preferred defaults and reads the file to inspect from
#             -t | --target. Optionally, -l | --lines can be supplied,
#             appending `numbers` to the `--style` list.
#
#  Usage    :  bat-view --target <path/to/file> [-l]
#              bat-view -t <path/to/file> [-l]
#              bat-view -h | --help
#
#  Exit codes:
#     0  – success
#     1  – user error (missing option, unknown flag, etc.)
#     2  – underlying `bat` not found
#     3  – target file missing/unreadable
###############################################################################

set -euo pipefail

############################################################
# CONSTANTS
############################################################
# Default bat options, kept in a single, readable array.
BAT_OPTS=(
  --theme="gruvbox-dark"
  --style="grid,header,snip"
  --strip-ansi="auto"
  --squeeze-blank
  --squeeze-limit="2"
  --paging="never"
  --decorations="always"
  --color="always"
  --italic-text="always"
  --terminal-width="-2"
  --tabs="1"
)

############################################################
# HELP
############################################################
show_help() {
  # Prefer rendering as Markdown through helpout/batwrap when available.
  if command -v helpout >/dev/null 2>&1; then
    helpout -l md <<'EOF'

# `bat-view — display a file with `bat` using fixed defaults

**Synopsis**
- `bat-view -t <file>`
- `bat-view --lines --target <file>`
- `bat-view -l -t <file>`
- `bat-view -h | --help`

**Description**  
Wraps `bat` with the following defaults (except `--style`):
- `--theme="gruvbox-dark"`
- `--style="grid,header,snip"`
- `--strip-ansi="auto"`
- `--squeeze-blank` `--squeeze-limit="2"`
- `--paging="never"`
- `--decorations="always"`
- `--color="always"`
- `--italic-text="always"`
- `--terminal-width="-2"`
- `--tabs="1"`

When `-l | -L | --lines | --line-numbers` is set, **numbers** is appended to `--style`, becoming:
```bash
--style="grid,header,snip,numbers"
```

**Options**
- `-t, --target FILE` — file to display (required)
- `-l, -L, --lines, --line-numbers` — show line numbers
- `-h, --help` — show this help and exit

**Examples**
- `bat-view -t /etc/mkinitcpio.conf`
- `bat-view -l -t /etc/fstab`
EOF
    return
  fi

  if command -v batwrap >/dev/null 2>&1; then
    batwrap -l md <<'EOF'
# `bat-view` — display a file with `bat` using fixed defaults

**Synopsis**
- `bat-view -t <file>`
- `bat-view --lines --target <file>`
- `bat-view -l -t <file>`
- `bat-view -h | --help`

**Description**  
Wraps `bat` with the following defaults (except `--style`):
- `--theme="gruvbox-dark"`
- `--style="grid,header,snip"`
- `--strip-ansi="auto"`
- `--squeeze-blank` `--squeeze-limit="2"`
- `--paging="never"`
- `--decorations="always"`
- `--color="always"`
- `--italic-text="always"`
- `--terminal-width="-2"`
- `--tabs="1"`

When `-l | -L | --lines | --line-numbers` is set, **numbers** is appended to `--style`, becoming:
```
--style="grid,header,snip,numbers"
```

**Options**
- `-t, --target FILE` — file to display (required)
- `-l, -L, --lines, --line-numbers` — show line numbers
- `-h, --help` — show this help and exit

**Examples**
- `bat-view -t /etc/mkinitcpio.conf`
- `bat-view -l -t /etc/fstab`
EOF
    return
  fi

  # Plain fallback.
  cat <<'EOF'
bat-view – display a file with bat using fixed defaults

SYNOPSIS
  bat-view -t <file>
  bat-view --lines --target <file>
  bat-view -l -t <file>
  bat-view -h | --help

DESCRIPTION
  Wraps the bat command with fixed defaults (except --style).
  When -l|--lines is set, "numbers" is appended to --style.

OPTIONS
  -t, --target FILE          File to display (required).
  -l, -L, --lines, --line-numbers
                             Show line numbers in output.
  -h, --help                 Show this help and exit.

EXAMPLES
  bat-view -t /etc/mkinitcpio.conf
  bat-view -l -t /etc/fstab
EOF
}

############################################################
# UTIL
############################################################
die() { printf 'bat-view: %s\n' "$*" >&2; exit 1; }

append_numbers_style_if_needed() {
  # Append ",numbers" to the first --style=… entry if not already present.
  local i
  for i in "${!BAT_OPTS[@]}"; do
    if [[ ${BAT_OPTS[$i]} == --style=* ]]; then
      # Normalize quotes for the check by stripping surrounding quotes after '='.
      local val="${BAT_OPTS[$i]#--style=}"
      val="${val%\"}"; val="${val#\"}"   # strip "
      val="${val%\' }"; val="${val#\'}"   # strip '
      if [[ $val != *numbers* ]]; then
        # Append within existing quotes if present; otherwise add plainly.
        if [[ ${BAT_OPTS[$i]} == --style=\"*\" ]]; then
          BAT_OPTS[$i]="--style=\"${val},numbers\""
        elif [[ ${BAT_OPTS[$i]} == --style=\'*\' ]]; then
          BAT_OPTS[$i]="--style='${val},numbers'"
        else
          BAT_OPTS[$i]="--style=${val},numbers"
        fi
      fi
      return
    fi
  done
  # If no --style entry existed (unlikely here), add one.
  BAT_OPTS+=("--style=\"grid,header,snip,numbers\"")
}

############################################################
# PREREQUISITE CHECK
############################################################
if ! command -v bat >/dev/null 2>&1; then
  die "bat is not installed or not in PATH." # exit 1
fi

############################################################
# ARGUMENT PARSING
############################################################
TARGET=""

while (($#)); do
  case "$1" in
    -t|--target)
      (($# >= 2)) || die "option '$1' requires a path argument."
      TARGET=$2
      shift 2
      ;;
    -l|-L|--lines|--line-numbers)
      append_numbers_style_if_needed
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      die "unexpected argument: $1 (use -t|--target)"
      ;;
  esac
done

# Final validation
[[ -n "$TARGET" ]] || die "no target file supplied. Use -t|--target <file>."
[[ -r "$TARGET" ]] || { printf 'bat-view: cannot read: %s\n' "$TARGET" >&2; exit 3; }

############################################################
# MAIN
############################################################
# shellcheck disable=SC2086
exec bat "${BAT_OPTS[@]}" "$TARGET"
