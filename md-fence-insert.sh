#!/usr/bin/env bash

set -euo pipefail

show_help() {
  cat <<'EOF'
Usage:
  md-fence-insert [LANG]

Description:
  Types a Markdown code fence into the currently focused window.

  If LANG is omitted, inserts:

    ```
    
    ```

  If LANG is provided, inserts:

    ```lang
    
    ```

  After insertion, the cursor is moved to the empty line between the fences.

Examples:
  md-fence-insert
  md-fence-insert r
  md-fence-insert python
  md-fence-insert bash
  md-fence-insert sql
EOF
}

function require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Error: required command not found: %s\n' "$1" >&2
    exit 1
  }
}

main() {
  local lang opening

  case "${1:-}" in
    -h|--help)
      show_help
      exit 0
      ;;
  esac

  require_cmd wtype

  lang="${1:-}"
  lang="${lang,,}"

  if [[ -n "$lang" ]]; then
    opening="\`\`\`${lang}"
  else
    opening="\`\`\`"
  fi

  wtype "$opening"
  wtype -k Return
  wtype -k Return
  wtype "\`\`\`"
  wtype -k Up
  wtype -k Home
}

main "$@"
