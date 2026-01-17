#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# pacman-perms-audit
#
# Parse pacman -Qkk mismatch warnings, explain them, and optionally apply
# only canonical, high-confidence fixes for:
#   - /usr/share/polkit-1/rules.d  (root:root 0755)
#   - /var/log/journal             (root:systemd-journal 2755 + tmpfiles)
#
# Everything else is reported with current stat + mtree line for manual review.
# -----------------------------------------------------------------------------

set -euo pipefail

function usage() {
  cat <<'EOF'
pacman-perms-audit

USAGE
  pacman-perms-audit [--check] [--apply] [--prefix PATH] [--ignore REGEX]

DESCRIPTION
  Reads pacman integrity warnings (via pacman -Qkk by default), and prints
  per-warning diagnostics:
    - package name
    - path
    - mismatch type (Permissions/GID/UID/etc)
    - current stat (mode + owner:group)
    - the package mtree line for that path (if found)

  With --apply, performs ONLY two canonical fixes:
    1) /usr/share/polkit-1/rules.d  => root:root 0755
    2) /var/log/journal             => root:systemd-journal 2755, then
                                      systemd-tmpfiles --create --prefix

OPTIONS
  --check
      Run: pacman -Qkk (default if stdin is a TTY).

  --apply
      Apply only the canonical fixes described above.

  --prefix PATH
      Only show mismatches for paths beginning with PATH.

  --ignore REGEX
      Skip any mismatch where the PATH matches REGEX.

NOTES
  - Shared directories can be "owned" by many packages and their mtree entries
    may disagree; you cannot satisfy them all simultaneously.
  - This tool does not chmod/chown arbitrary paths automatically, by design.

EOF
}

function have_cmd() { command -v "$1" >/dev/null 2>&1; }

function pager() {
  local p="${HELP_PAGER:-}"
  if [[ -n "${p}" ]]; then
    echo "${p}"
    return
  fi
  if have_cmd less; then
    echo "less -R"
  else
    echo "cat"
  fi
}

function as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
    return
  fi
  if have_cmd sudo; then
    sudo "$@"
    return
  fi
  echo "error: need root or sudo: $*" >&2
  exit 1
}

APPLY=0
DO_CHECK=0
PREFIX=""
IGNORE_REGEX=""

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage | eval "$(pager)"
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) DO_CHECK=1; shift ;;
    --apply) APPLY=1; shift ;;
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --ignore) IGNORE_REGEX="${2:-}"; shift 2 ;;
    -h|--help)
      usage | eval "$(pager)"
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

function stat_line() {
  local path="$1"
  if [[ -e "$path" ]]; then
    stat -c '%A %a %U:%G %n' "$path" 2>/dev/null || true
  else
    echo "(missing) $path"
  fi
}

function mtree_line() {
  local pkg="$1"
  local path="$2"
  local rel="./${path#/}"
  local mtree
  mtree="$(ls -1 /var/lib/pacman/local/"${pkg}"-*/mtree 2>/dev/null | head -n 1 || true)"
  if [[ -z "${mtree}" ]]; then
    return
  fi
  zgrep -a -m 1 -F "${rel} " "${mtree}" 2>/dev/null || true
}

function apply_canonical_fix() {
  local path="$1"
  case "$path" in
    /usr/share/polkit-1/rules.d)
      as_root install -d -o root -g root -m 0755 /usr/share/polkit-1/rules.d
      ;;
    /var/log/journal)
      as_root install -d -o root -g systemd-journal -m 2755 /var/log/journal
      as_root systemd-tmpfiles --create --prefix=/var/log/journal
      ;;
    *)
      return
      ;;
  esac
}

INPUT=""
if [[ -t 0 ]]; then
  DO_CHECK=1
fi

if [[ "${DO_CHECK}" -eq 1 ]]; then
  INPUT="$(as_root env LC_ALL=C pacman -Qkk 2>&1 || true)"
else
  INPUT="$(cat)"
fi

# Extract lines like:
# warning: <pkg>: <path> (<kind mismatch>)
echo "${INPUT}" \
| awk '
  $1=="warning:" {
    # Example: warning: polkit: /usr/share/polkit-1/rules.d (Permissions mismatch)
    pkg=$2; sub(/:$/,"",pkg)
    path=$3
    kind=""
    for (i=4; i<=NF; i++) { kind = kind $i (i==NF ? "" : " ") }
    print pkg "\t" path "\t" kind
  }
' \
| while IFS=$'\t' read -r pkg path kind; do
    if [[ -n "${PREFIX}" && "${path}" != "${PREFIX}"* ]]; then
      continue
    fi
    if [[ -n "${IGNORE_REGEX}" && "${path}" =~ ${IGNORE_REGEX} ]]; then
      continue
    fi

    echo "-----------------------------------------------------------------"
    echo "package : ${pkg}"
    echo "path    : ${path}"
    echo "issue   : ${kind}"
    echo "stat    : $(stat_line "${path}")"

    ml="$(mtree_line "${pkg}" "${path}")"
    if [[ -n "${ml}" ]]; then
      echo "mtree   : ${ml}"
    else
      echo "mtree   : (not found for this path in ${pkg})"
    fi

    if [[ "${APPLY}" -eq 1 ]]; then
      if [[ "${path}" == "/usr/share/polkit-1/rules.d" \
         || "${path}" == "/var/log/journal" ]]; then
        echo "action  : applying canonical fix"
        apply_canonical_fix "${path}"
        echo "after   : $(stat_line "${path}")"
      else
        echo "action  : (no auto-fix; manual review)"
      fi
    fi
  done

