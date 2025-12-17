function rgfd() {
  #----------------------------------------------------------------------------
  # rgfd: "fd, but for file contents" (ripgrep wrapper)
  #
  # Usage:
  #   rgfd [OPTIONS] <pattern> [root]
  #
  # Modes:
  #   --files           List matching files (default)
  #   --lines           Show matching lines (rg-like output)
  #   --count           Rank files by match count
  #   --dircount        Rank directories by total match count
  #
  # Common options:
  #   -i, --ignore-case     Case-insensitive search
  #   -F, --fixed           Treat pattern as literal (no regex)
  #   --hidden              Include hidden files (rg --hidden)
  #   --all                 Include ignored/hidden/binary (rg -uuu)
  #   -g, --glob <GLOB>     Add a glob filter (repeatable)
  #   --top <N>             Limit ranked output to top N rows
  #   -h, --help            Show help
  #
  # Pass-through:
  #   Use `--` to pass additional raw arguments to rg.
  #   Example:
  #     rgfd --lines exec-once ~/.config -- -S
  #----------------------------------------------------------------------------

  local mode="files"
  local ignore_case="false"
  local fixed="false"
  local hidden="false"
  local all="false"
  local top_n=""
  local root="."
  local pattern=""

  local -a globs
  local -a pass

  function _rgfd_pager() {
    if [[ -n "${HELP_PAGER:-}" ]]; then
      eval "${HELP_PAGER}"
    elif command -v less >/dev/null 2>&1; then
      less -R
    else
      cat
    fi
  }

  function _rgfd_help() {
    cat <<'EOF' | _rgfd_pager
# rgfd

A small wrapper around ripgrep that makes "search by contents" feel like `fd`.

## Examples

List files containing `exec-once` under ~/.config:
  rgfd exec-once ~/.config

Show matching lines with line numbers:
  rgfd --lines exec-once ~/.config

Rank files by number of matches (descending):
  rgfd --count exec-once ~/.config

Rank directories by total matches (descending):
  rgfd --dircount exec-once ~/.config

Restrict to certain config files:
  rgfd -g'*.conf' -g'*.toml' -g'*.sh' exec-once ~/.config

Case-insensitive, literal search:
  rgfd -i -F 'Exec-Once' ~/.config

Pass extra rg flags after `--`:
  rgfd --lines exec-once ~/.config -- -S

## Options

Modes:
  --files      Print only matching filenames (default)
  --lines      Print matching lines (rg default style)
  --count      Print "count<TAB>file" sorted descending
  --dircount   Print "count<TAB>dir" sorted descending

Other:
  -i, --ignore-case
  -F, --fixed
  --hidden
  --all
  -g, --glob <GLOB>   (repeatable)
  --top <N>
  -h, --help
EOF
  }

  if ! command -v rg >/dev/null 2>&1; then
    printf 'rgfd: error: ripgrep (rg) not found in PATH\n' >&2
    return 127
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --files) mode="files" ;;
      --lines) mode="lines" ;;
      --count) mode="count" ;;
      --dircount) mode="dircount" ;;
      -i|--ignore-case) ignore_case="true" ;;
      -F|--fixed|--fixed-strings) fixed="true" ;;
      --hidden) hidden="true" ;;
      --all) all="true" ;;
      -g|--glob)
        shift
        [[ $# -gt 0 ]] || { printf 'rgfd: missing arg for --glob\n' >&2; return 2; }
        globs+=("$1")
        ;;
      --top)
        shift
        [[ $# -gt 0 ]] || { printf 'rgfd: missing arg for --top\n' >&2; return 2; }
        top_n="$1"
        ;;
      -h|--help)
        _rgfd_help
        return 0
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          pass+=("$1")
          shift
        done
        break
        ;;
      -*)
        printf 'rgfd: unknown option: %s\n' "$1" >&2
        printf 'rgfd: run: rgfd --help\n' >&2
        return 2
        ;;
      *)
        if [[ -z "$pattern" ]]; then
          pattern="$1"
        elif [[ "$root" == "." ]]; then
          root="$1"
        else
          pass+=("$1")
        fi
        ;;
    esac
    shift
  done

  if [[ -z "$pattern" ]]; then
    _rgfd_help
    return 2
  fi

  local -a rg_args
  if [[ "$ignore_case" == "true" ]]; then
    rg_args+=("-i")
  fi
  if [[ "$fixed" == "true" ]]; then
    rg_args+=("-F")
  fi
  if [[ "$all" == "true" ]]; then
    rg_args+=("-uuu")
  elif [[ "$hidden" == "true" ]]; then
    rg_args+=("--hidden")
  fi
  for g in "${globs[@]:-}"; do
    rg_args+=("-g" "$g")
  done

  case "$mode" in
    files)
      rg "${rg_args[@]}" -l -- "$pattern" "$root" "${pass[@]:-}"
      ;;
    lines)
      rg "${rg_args[@]}" -n -- "$pattern" "$root" "${pass[@]:-}"
      ;;
    count)
      rg "${rg_args[@]}" --count-matches -- "$pattern" "$root" "${pass[@]:-}" \
        | sort -t: -k2,2nr \
        | awk -F: '{ printf "%s\t%s\n", $2, $1 }' \
        | { if [[ -n "$top_n" ]]; then head -n "$top_n"; else cat; fi; }
      ;;
    dircount)
      rg "${rg_args[@]}" --count-matches -- "$pattern" "$root" "${pass[@]:-}" \
        | awk -F: -v base="$root" '
            function norm(p) {
              sub(/\/+$/, "", p)
              return p
            }
            {
              file=$1; cnt=$2
              dir=file
              sub(/\/[^\/]+$/, "", dir)
              base2=norm(base)
              if (base2 != "." && index(dir, base2) == 1) {
                dir=substr(dir, length(base2) + 2)
                if (dir == "") dir="."
              }
              sum[dir] += cnt
            }
            END {
              for (d in sum) printf "%d\t%s\n", sum[d], d
            }
          ' \
        | sort -k1,1nr \
        | { if [[ -n "$top_n" ]]; then head -n "$top_n"; else cat; fi; }
      ;;
    *)
      printf 'rgfd: internal error: unknown mode: %s\n' "$mode" >&2
      return 3
      ;;
  esac
}
