#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# pacperm-audit.sh
#
# Audit (and optionally fix) permission mismatches reported by `pacman -Qkk`,
# restricted to packages that own files under a given PATH prefix.
#
# Default: report only.
# -----------------------------------------------------------------------------

function show_help() {
  cat <<'EOF'
pacperm-audit.sh — Audit/fix pacman permission mismatches under a path

USAGE:
  sudo ./pacperm-audit.sh --path /some/prefix [--fix-risky|--fix-all] [--apply]

OPTIONS:
  --path PATH       Absolute path prefix to audit (default: /).
  --fix-risky       Fix only when filesystem is MORE permissive than package.
                    (Tighten-only; never adds permissions.)
  --fix-all         Fix all mismatches to match the package exactly.
  --apply           Actually perform chmod changes. Without this: dry-run.
  --verbose         Print extra diagnostics.
  -h, --help        Show this help.

NOTES:
  - This only handles mismatches where pacman provides both filesystem and
    package mode numbers. It intentionally does not guess owners/groups.
  - For owner/group mismatches, the safest remediation is usually reinstalling
    the affected package(s) rather than scripting chown heuristics.

EXAMPLES:
  sudo ./pacperm-audit.sh --path /usr --fix-risky
  sudo ./pacperm-audit.sh --path /usr --fix-risky --apply
  sudo ./pacperm-audit.sh --path /etc --fix-all --apply
EOF
}

function die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

function require_root() {
  if [[ ${EUID:-0} -ne 0 ]]; then
    die "Run as root (use sudo)."
  fi
}

function norm_path() {
  local p="$1"
  [[ -z "$p" ]] && die "--path cannot be empty"
  [[ "$p" != /* ]] && die "--path must be absolute (got: $p)"
  p="${p%/}"
  [[ -z "$p" ]] && p="/"
  printf '%s\n' "$p"
}

function regex_escape() {
  # Escape characters meaningful to ERE.
  sed 's/[][(){}.^$*+?|\\/]/\\&/g' <<<"$1"
}

function pkg_name_from_desc() {
  local desc="$1"
  awk '$0=="%NAME%"{getline; print; exit}' "$desc"
}

function pkgs_for_prefix() {
  local prefix_abs="$1"
  local prefix_rel="${prefix_abs#/}"
  local pattern esc
  local -a hits=()
  local -a pkgs=()

  if [[ "$prefix_abs" == "/" ]]; then
    pacman -Qq
    return 0
  fi

  esc="$(regex_escape "$prefix_rel")"
  pattern="^${esc}(/|$)"

  # Match package db entries that list files under the prefix.
  # The local database is: /var/lib/pacman/local/<pkg>-<ver>/{files,desc}
  while IFS= read -r f; do
    hits+=("$f")
  done < <(grep -REl -- "$pattern" /var/lib/pacman/local/*/files 2>/dev/null || true)

  if [[ ${#hits[@]} -eq 0 ]]; then
    return 0
  fi

  local files_file pkgdir name
  for files_file in "${hits[@]}"; do
    pkgdir="$(dirname "$files_file")"
    if [[ -f "${pkgdir}/desc" ]]; then
      name="$(pkg_name_from_desc "${pkgdir}/desc")"
      [[ -n "$name" ]] && pkgs+=("$name")
    fi
  done

  # Unique-ify.
  printf '%s\n' "${pkgs[@]}" | awk '!seen[$0]++'
}

function mode_relation() {
  # Prints one of: more-permissive | more-restrictive | incomparable | equal
  local fs="$1" pkg="$2"
  if [[ "$fs" == "$pkg" ]]; then
    printf 'equal\n'
    return 0
  fi

  local fs_i pkg_i
  fs_i=$((8#$fs))
  pkg_i=$((8#$pkg))

  if (( (fs_i | pkg_i) == fs_i )); then
    # fs contains all pkg bits (and some extra)
    printf 'more-permissive\n'
    return 0
  fi
  if (( (fs_i | pkg_i) == pkg_i )); then
    # pkg contains all fs bits (fs is a subset)
    printf 'more-restrictive\n'
    return 0
  fi
  printf 'incomparable\n'
}

function audit_and_maybe_fix() {
  local prefix_abs="$1"
  local fix_mode="$2"   # none | risky | all
  local apply="$3"      # 0 | 1
  local verbose="$4"    # 0 | 1

  local -a pkgs=()
  while IFS= read -r p; do
    pkgs+=("$p")
  done < <(pkgs_for_prefix "$prefix_abs")

  if [[ ${#pkgs[@]} -eq 0 ]]; then
    printf 'No owning packages found under prefix: %s\n' "$prefix_abs"
    return 0
  fi

  (( verbose )) && printf 'Checking %d package(s)...\n' "${#pkgs[@]}" >&2

  local out
  out="$(pacman -Qkk "${pkgs[@]}" 2>&1 || true)"

  local pending_path=""
  local line path fs pkg rel action
  local found=0

  while IFS= read -r line; do
    # Pattern 1 (seen during upgrades):
    #   warning: directory permissions differ on /path/
    #   filesystem: 750  package: 755
    if [[ "$line" =~ ^warning:\ directory\ permissions\ differ\ on\ (.+)$ ]]; then
      pending_path="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ -n "$pending_path" && "$line" =~ ^filesystem:\ ([0-9]{3,4})[[:space:]]+package:\ ([0-9]{3,4})$ ]]; then
      path="$pending_path"
      fs="${BASH_REMATCH[1]}"
      pkg="${BASH_REMATCH[2]}"
      pending_path=""
    # Pattern 2 (common in pacman -Qkk):
    # warning: pkg: /path (permissions mismatch (filesystem: 755, package: 750))
    elif [[ "$line" =~ ^warning:.*\ ([/].*)\ \(.+filesystem:\ ([0-9]{3,4}).*package:\ ([0-9]{3,4}).*\)$ ]]; then
      path="${BASH_REMATCH[1]}"
      fs="${BASH_REMATCH[2]}"
      pkg="${BASH_REMATCH[3]}"
    else
      continue
    fi

    # Restrict output to the requested prefix.
    if [[ "$prefix_abs" != "/" ]]; then
      local prefix_slash="${prefix_abs%/}/"
      if [[ "$path" != "$prefix_abs" && "$path" != "$prefix_slash"* ]]; then
        continue
      fi
    fi

    found=1
    rel="$(mode_relation "$fs" "$pkg")"
    action="report"

    if [[ "$fix_mode" == "risky" && "$rel" == "more-permissive" ]]; then
      action="chmod $pkg"
      if (( apply )); then
        chmod "$pkg" -- "$path"
      fi
    elif [[ "$fix_mode" == "all" && "$rel" != "equal" ]]; then
      action="chmod $pkg"
      if (( apply )); then
        chmod "$pkg" -- "$path"
      fi
    fi

    if (( apply )); then
      printf '%s: %s (fs=%s pkg=%s) -> %s\n' \
        "$rel" "$path" "$fs" "$pkg" "$action"
    else
      printf '%s: %s (fs=%s pkg=%s) -> would %s\n' \
        "$rel" "$path" "$fs" "$pkg" "$action"
    fi
  done <<<"$out"

  if (( ! found )); then
    printf 'No permission mismatches found under prefix: %s\n' "$prefix_abs"
  fi
}

function main() {
  local prefix="/"
  local fix_mode="none"
  local apply=0
  local verbose=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path)
        shift
        [[ $# -gt 0 ]] || die "--path requires a value"
        prefix="$(norm_path "$1")"
        ;;
      --fix-risky)
        fix_mode="risky"
        ;;
      --fix-all)
        fix_mode="all"
        ;;
      --apply)
        apply=1
        ;;
      --verbose)
        verbose=1
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
    shift
  done

  require_root
  audit_and_maybe_fix "$prefix" "$fix_mode" "$apply" "$verbose"
}

main "$@"
