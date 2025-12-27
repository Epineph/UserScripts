#!/usr/bin/env bash
set -euo pipefail

function usage() {
  cat <<'USAGE'
pacman-output-audit

Purpose:
  Parse pacman transaction output (captured stdout/stderr) and extract:
    - optional dependencies (with [installed]/[pending] if present)
    - installs/removals
    - warnings and errors
  Output is written into an output directory.

Usage:
  pacman-output-audit --in FILE [--outdir DIR]
  pacman-output-audit --clipboard [--outdir DIR]
  pacman-output-audit [--outdir DIR] < FILE

Options:
  -i, --in FILE         Input file containing pacman output.
  -o, --outdir DIR      Output directory. Default: ./pacman-audit-YYYY-MM-DD_HHMMSS
      --clipboard       Read input from clipboard (wl-paste, else xclip, else xsel).
  -h, --help            Show this help.

Outputs (in outdir):
  raw.txt
  optional_deps.tsv
  optional_deps_pending.tsv
  package_actions.tsv
  warnings.txt
  errors.txt
USAGE
}

in_file=""
outdir=""
from_clipboard="0"

while [ $# -gt 0 ]; do
  case "$1" in
    -i|--in) in_file="${2:-}"; shift 2;;
    -o|--outdir) outdir="${2:-}"; shift 2;;
    --clipboard) from_clipboard="1"; shift 1;;
    -h|--help) usage; exit 0;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2;;
  esac
done

ts="$(date +%F_%H%M%S)"
if [ -z "$outdir" ]; then
  outdir="./pacman-audit-$ts"
fi
mkdir -p "$outdir"

raw="$outdir/raw.txt"

if [ "$from_clipboard" = "1" ]; then
  if command -v wl-paste >/dev/null 2>&1; then
    wl-paste > "$raw"
  elif command -v xclip >/dev/null 2>&1; then
    xclip -o -selection clipboard > "$raw"
  elif command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --output > "$raw"
  else
    printf 'No clipboard tool found (need wl-paste, xclip, or xsel).\n' >&2
    exit 1
  fi
elif [ -n "$in_file" ]; then
  cp -f -- "$in_file" "$raw"
else
  cat > "$raw"
fi

python3 - "$raw" "$outdir" <<'PY'
import re
import sys
from pathlib import Path

raw_path = Path(sys.argv[1])
outdir = Path(sys.argv[2])
lines = raw_path.read_text(errors="replace").splitlines()

opt_rows = []
actions = []
warnings = []
errors = []

current_pkg = None

re_opt_hdr = re.compile(r"^Optional dependencies for (.+?)\s*$")
re_opt_item = re.compile(r"^\s+(\S+):\s*(.*)$")
re_status = re.compile(r"(.*?)\s*\[([^\]]+)\]\s*$")

re_action = re.compile(r"^\(\s*\d+/\d+\)\s+(installing|removing)\s+(\S+)")
re_warning = re.compile(r"^warning:\s*(.*)$")
re_error = re.compile(r"^error:\s*(.*)$")

def flush_pkg_if_needed(line: str):
  global current_pkg
  if current_pkg is None:
    return
  if line.strip() == "":
    return
  if not line.startswith((" ", "\t")):
    current_pkg = None

for line in lines:
  if re_warning.match(line):
    warnings.append(line)
  if re_error.match(line):
    errors.append(line)

  m = re_action.match(line)
  if m:
    actions.append((m.group(1), m.group(2)))

  m = re_opt_hdr.match(line)
  if m:
    current_pkg = m.group(1).strip()
    continue

  if current_pkg is not None:
    m = re_opt_item.match(line)
    if m:
      dep = m.group(1).strip()
      rest = m.group(2).strip()
      status = "unknown"
      desc = rest
      sm = re_status.match(rest)
      if sm:
        desc = sm.group(1).strip()
        status = sm.group(2).strip()
      opt_rows.append((current_pkg, dep, status, desc))
      continue
    flush_pkg_if_needed(line)

(outdir / "optional_deps.tsv").write_text(
  "package\tdependency\tstatus\tdescription\n"
  + "\n".join(f"{p}\t{d}\t{s}\t{c}" for p, d, s, c in opt_rows)
  + ("\n" if opt_rows else ""),
  encoding="utf-8"
)

pending = [r for r in opt_rows if r[2].lower() == "pending"]
(outdir / "optional_deps_pending.tsv").write_text(
  "package\tdependency\tstatus\tdescription\n"
  + "\n".join(f"{p}\t{d}\t{s}\t{c}" for p, d, s, c in pending)
  + ("\n" if pending else ""),
  encoding="utf-8"
)

(outdir / "package_actions.tsv").write_text(
  "action\tpackage\n"
  + "\n".join(f"{a}\t{p}" for a, p in actions)
  + ("\n" if actions else ""),
  encoding="utf-8"
)

(outdir / "warnings.txt").write_text(
  "\n".join(warnings) + ("\n" if warnings else ""),
  encoding="utf-8"
)

(outdir / "errors.txt").write_text(
  "\n".join(errors) + ("\n" if errors else ""),
  encoding="utf-8"
)

print(f"Outdir: {outdir}")
print(f"Optional deps: {len(opt_rows)}  (pending: {len(pending)})")
print(f"Actions: {len(actions)}  Warnings: {len(warnings)}  Errors: {len(errors)}")
PY

printf 'Wrote report to: %s\n' "$outdir"

