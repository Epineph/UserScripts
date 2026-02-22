#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# browser-bench.sh
#
# Systematic, repeatable browser resource logging for Arch Linux.
#
# What it does:
#   - Launches a browser with an isolated, disposable profile per run.
#   - Opens a given URL.
#   - Samples CPU% (approx) + memory (RSS, aggregated over the browser process
#     tree) at a fixed interval.
#   - Writes per-sample data to CSV + a per-run summary CSV.
#
# What it does NOT do:
#   - It does not “click Start” in benchmarks. You do that manually.
#     The point is to make the measurement repeatable and captured as data.
#
# Dependencies:
#   - bash, coreutils, procps (ps), util-linux (flock is not used), awk
#   - No AUR required.
#
# =============================================================================

function usage() {
  cat <<'EOF'
Usage:
  browser-bench.sh run \
    --browser <cmd> \
    --name <label> \
    --scenario <name> \
    --url <url> \
    [--runs N] \
    [--duration SEC] \
    [--interval SEC] \
    [--warmup SEC] \
    [--outdir DIR] \
    [--keep-profile]

Examples:
  # 1) Baseline idle (about:blank)
  browser-bench.sh run --browser chromium --name chromium \
    --scenario idle --url about:blank --runs 5 --duration 120

  # 2) Speedometer (you click "Start Test" in the page)
  browser-bench.sh run --browser chromium --name chromium \
    --scenario speedometer --url https://browserbench.org/Speedometer3.0/ \
    --runs 5 --duration 600 --warmup 10

  # 3) JetStream (you click "Start Test")
  browser-bench.sh run --browser thorium-browser --name thorium \
    --scenario jetstream --url https://browserbench.org/JetStream2.0/ \
    --runs 5 --duration 600 --warmup 10

  # 4) YouTube video test (you start playback and pick 1080p60 manually)
  browser-bench.sh run --browser chromium --name chromium \
    --scenario yt1080p --url https://www.youtube.com/watch?v=dQw4w9WgXcQ \
    --runs 3 --duration 180 --warmup 10

Outputs:
  OUTDIR/
    samples.csv        (one row per sample)
    runs.csv           (one row per run, summary stats)
    profiles/          (only if --keep-profile is used)

Notes:
  - Use identical window size, extensions disabled, and same Wayland/X11 mode
    across browsers if you want clean comparisons.
  - For benchmarks, start the test right after warmup ends (script prints a cue).
EOF
}

function die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

function require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"
}

function now_iso() {
  date -Is
}

function sanitize() {
  # Replace problematic chars for filenames.
  printf '%s' "$1" | tr ' /:' '___'
}

function mk_outdir() {
  local base="$1"
  local name="$2"
  local scenario="$3"
  local ts
  ts="$(date -Is | tr ':' '-')"
  printf '%s/%s/%s/%s' "$base" "$(sanitize "$name")" "$(sanitize "$scenario")" \
    "$(sanitize "$ts")"
}

function list_tree_pids() {
  # Print PID + all descendants, one per line.
  # Uses recursive PS traversal (portable enough for Arch).
  local root_pid="$1"

  # BFS-style expansion.
  local -a queue
  local -A seen
  queue=("$root_pid")
  seen["$root_pid"]=1

  while ((${#queue[@]} > 0)); do
    local pid="${queue[0]}"
    queue=("${queue[@]:1}")
    printf '%s\n' "$pid"

    # Children of pid:
    # ps output: " PID"
    while IFS= read -r child; do
      [[ -z "$child" ]] && continue
      if [[ -z "${seen[$child]:-}" ]]; then
        seen["$child"]=1
        queue+=("$child")
      fi
    done < <(ps -o pid= --ppid "$pid" 2>/dev/null | awk '{print $1}')
  done
}

function read_proc_jiffies_total() {
  # Total CPU jiffies from /proc/stat line "cpu  ..."
  # Returns: sum(user,nice,system,idle,iowait,irq,softirq,steal,guest,guest_nice)
  awk 'NR==1 && $1=="cpu"{
    s=0; for(i=2;i<=NF;i++) s+=$i; print s
  }' /proc/stat
}

function read_proc_jiffies_pid() {
  # Process utime+stime from /proc/PID/stat
  # Field 14 = utime, 15 = stime (1-indexed)
  local pid="$1"
  awk '{print $14+$15}' "/proc/${pid}/stat" 2>/dev/null || echo 0
}

function read_rss_kb_pid() {
  # VmRSS in kB from /proc/PID/status
  local pid="$1"
  awk '$1=="VmRSS:"{print $2}' "/proc/${pid}/status" 2>/dev/null || echo 0
}

function sum_rss_kb_tree() {
  local root_pid="$1"
  local sum=0
  local pid rss
  while IFS= read -r pid; do
    rss="$(read_rss_kb_pid "$pid")"
    # rss is numeric kB
    sum=$((sum + rss))
  done < <(list_tree_pids "$root_pid")
  printf '%s' "$sum"
}

function sum_jiffies_tree() {
  local root_pid="$1"
  local sum=0
  local pid j
  while IFS= read -r pid; do
    j="$(read_proc_jiffies_pid "$pid")"
    sum=$((sum + j))
  done < <(list_tree_pids "$root_pid")
  printf '%s' "$sum"
}

function approx_cpu_pct_interval() {
  # Approx CPU% over an interval, for the whole browser process tree:
  #
  # Let:
  #   ΔJ_proc = delta jiffies (proc utime+stime summed over tree)
  #   ΔJ_tot  = delta jiffies (total CPU)
  #
  # Then fraction of total CPU time:
  #   f = ΔJ_proc / ΔJ_tot
  #
  # Convert to percent:
  #   CPU% = 100 * f
  #
  # This is *aggregate across all cores* relative to the whole machine.
  # A fully loaded single core on an 8-core machine is ~12.5% by this metric.
  local dproc="$1"
  local dtot="$2"
  awk -v a="$dproc" -v b="$dtot" 'BEGIN{
    if (b<=0) {print 0; exit}
    printf "%.3f", (100.0*a)/b
  }'
}

function median_of_file() {
  # Median of numeric column (1-based) from a CSV-like file (comma-separated),
  # skipping header. Assumes no commas in numeric field.
  local file="$1"
  local col="$2"
  awk -F',' -v c="$col" 'NR>1 {print $c}' "$file" | sort -n | awk '
    {a[NR]=$1}
    END{
      if (NR==0) {print ""; exit}
      if (NR%2==1) {print a[(NR+1)/2]}
      else {print (a[NR/2]+a[NR/2+1])/2}
    }'
}

function max_of_file() {
  local file="$1"
  local col="$2"
  awk -F',' -v c="$col" 'NR>1 {if($c>m||NR==2)m=$c} END{print m}' "$file"
}

function min_of_file() {
  local file="$1"
  local col="$2"
  awk -F',' -v c="$col" 'NR>1 {if($c<m||NR==2)m=$c} END{print m}' "$file"
}

function run_one() {
  local browser_cmd="$1"
  local name="$2"
  local scenario="$3"
  local url="$4"
  local duration="$5"
  local interval="$6"
  local warmup="$7"
  local outdir="$8"
  local keep_profile="$9"
  local run_idx="${10}"

  local run_id
  run_id="$(date +%s)-${run_idx}"

  local profile_dir
  profile_dir="$(mktemp -d -p "${outdir}" "profile.${name}.${scenario}.${run_id}.XXXXXXXX")"

  local samples_csv="${outdir}/samples.csv"
  local run_tmp="${outdir}/run.${run_id}.csv"

  # Launch browser (best-effort: reduce first-run noise, background networking).
  # Flags are Chromium-ish; if unsupported, they are ignored or may error.
  # If your browser errors on flags, remove them below.
  set +e
  "$browser_cmd" \
    --user-data-dir="$profile_dir" \
    --no-first-run \
    --disable-sync \
    --disable-background-networking \
    "$url" >/dev/null 2>&1 &
  set -e

  local root_pid="$!"
  sleep 0.2

  if ! kill -0 "$root_pid" 2>/dev/null; then
    die "Browser process did not start: ${browser_cmd}"
  fi

  printf '\n'
  printf 'Run %s/%s | %s | %s\n' "$run_idx" "$RUNS" "$name" "$scenario"
  printf 'PID: %s\n' "$root_pid"
  printf 'URL: %s\n' "$url"
  printf 'Warmup: %ss, then sampling for %ss at %ss interval\n' \
    "$warmup" "$duration" "$interval"
  printf '\n'

  if ((warmup > 0)); then
    printf 'Warmup... (do any manual prep now: resize window, start benchmark)\n'
    sleep "$warmup"
  fi

  printf 'Sampling START (t=0). Keep interaction consistent between runs.\n'

  # Per-run CSV (easier to compute summary stats).
  printf 'ts_iso,name,scenario,run_id,sample_idx,rss_kb,cpu_pct\n' >"$run_tmp"

  local prev_tot prev_proc
  prev_tot="$(read_proc_jiffies_total)"
  prev_proc="$(sum_jiffies_tree "$root_pid")"

  local t=0
  local sample_idx=0

  while ((t < duration)); do
    if ! kill -0 "$root_pid" 2>/dev/null; then
      printf 'Browser exited early at t=%ss; stopping sampling.\n' "$t"
      break
    fi

    sleep "$interval"
    t=$((t + interval))
    sample_idx=$((sample_idx + 1))

    local cur_tot cur_proc d_tot d_proc cpu_pct rss_kb ts_iso
    cur_tot="$(read_proc_jiffies_total)"
    cur_proc="$(sum_jiffies_tree "$root_pid")"

    d_tot=$((cur_tot - prev_tot))
    d_proc=$((cur_proc - prev_proc))

    cpu_pct="$(approx_cpu_pct_interval "$d_proc" "$d_tot")"
    rss_kb="$(sum_rss_kb_tree "$root_pid")"
    ts_iso="$(now_iso)"

    printf '%s,%s,%s,%s,%s,%s,%s\n' \
      "$ts_iso" "$name" "$scenario" "$run_id" "$sample_idx" "$rss_kb" "$cpu_pct" \
      >>"$run_tmp"

    prev_tot="$cur_tot"
    prev_proc="$cur_proc"
  done

  printf 'Sampling END. Close the browser window now (if still open).\n'

  # Attempt graceful terminate.
  kill -TERM "$root_pid" 2>/dev/null || true
  sleep 0.5
  kill -KILL "$root_pid" 2>/dev/null || true

  # Append to global samples.csv (create header once).
  if [[ ! -f "$samples_csv" ]]; then
    head -n 1 "$run_tmp" >"$samples_csv"
  fi
  tail -n +2 "$run_tmp" >>"$samples_csv"

  # Compute per-run summary stats (medians are robust).
  # Columns:
  #   6 rss_kb
  #   7 cpu_pct
  local rss_med rss_max rss_min cpu_med cpu_max cpu_min
  rss_med="$(median_of_file "$run_tmp" 6)"
  rss_max="$(max_of_file    "$run_tmp" 6)"
  rss_min="$(min_of_file    "$run_tmp" 6)"
  cpu_med="$(median_of_file "$run_tmp" 7)"
  cpu_max="$(max_of_file    "$run_tmp" 7)"
  cpu_min="$(min_of_file    "$run_tmp" 7)"

  local runs_csv="${outdir}/runs.csv"
  if [[ ! -f "$runs_csv" ]]; then
    printf 'name,scenario,run_id,samples,rss_med_kb,rss_min_kb,rss_max_kb,' \
      >>"$runs_csv"
    printf 'cpu_med_pct,cpu_min_pct,cpu_max_pct\n' >>"$runs_csv"
  fi

  local nsamp
  nsamp="$(awk 'END{print NR-1}' "$run_tmp")"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$name" "$scenario" "$run_id" "$nsamp" \
    "$rss_med" "$rss_min" "$rss_max" \
    "$cpu_med" "$cpu_min" "$cpu_max" \
    >>"$runs_csv"

  if [[ "$keep_profile" == "1" ]]; then
    mkdir -p "${outdir}/profiles"
    mv "$profile_dir" "${outdir}/profiles/${name}.${scenario}.${run_id}"
  else
    rm -rf -- "$profile_dir"
  fi

  rm -f -- "$run_tmp"
  printf 'Run saved. Summary appended to: %s\n' "$runs_csv"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
require_cmd ps
require_cmd awk
require_cmd sort
require_cmd date
require_cmd mktemp
require_cmd kill

SUBCMD="${1:-}"
shift || true

if [[ "$SUBCMD" != "run" ]]; then
  usage
  exit 1
fi

BROWSER=""
NAME=""
SCENARIO=""
URL=""

RUNS=5
DURATION=300
INTERVAL=1
WARMUP=10
OUTBASE="${HOME}/.cache/browser-bench"
KEEP_PROFILE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --browser)   BROWSER="${2:-}"; shift 2 ;;
    --name)      NAME="${2:-}"; shift 2 ;;
    --scenario)  SCENARIO="${2:-}"; shift 2 ;;
    --url)       URL="${2:-}"; shift 2 ;;
    --runs)      RUNS="${2:-}"; shift 2 ;;
    --duration)  DURATION="${2:-}"; shift 2 ;;
    --interval)  INTERVAL="${2:-}"; shift 2 ;;
    --warmup)    WARMUP="${2:-}"; shift 2 ;;
    --outdir)    OUTBASE="${2:-}"; shift 2 ;;
    --keep-profile) KEEP_PROFILE=1; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown arg: $1" ;;
  esac
done

[[ -n "$BROWSER"  ]] || die "--browser is required"
[[ -n "$NAME"     ]] || die "--name is required"
[[ -n "$SCENARIO" ]] || die "--scenario is required"
[[ -n "$URL"      ]] || die "--url is required"

[[ "$RUNS" =~ ^[0-9]+$      ]] || die "--runs must be an integer"
[[ "$DURATION" =~ ^[0-9]+$  ]] || die "--duration must be an integer (seconds)"
[[ "$INTERVAL" =~ ^[0-9]+$  ]] || die "--interval must be an integer (seconds)"
[[ "$WARMUP" =~ ^[0-9]+$    ]] || die "--warmup must be an integer (seconds)"

if ((INTERVAL <= 0)); then
  die "--interval must be >= 1"
fi

OUTDIR="$(mk_outdir "$OUTBASE" "$NAME" "$SCENARIO")"
mkdir -p "$OUTDIR"

printf 'Output directory: %s\n' "$OUTDIR"
printf 'Per-sample CSV:   %s/samples.csv\n' "$OUTDIR"
printf 'Per-run CSV:      %s/runs.csv\n' "$OUTDIR"
printf '\n'

for ((i=1; i<=RUNS; i++)); do
  run_one "$BROWSER" "$NAME" "$SCENARIO" "$URL" \
    "$DURATION" "$INTERVAL" "$WARMUP" "$OUTDIR" "$KEEP_PROFILE" "$i"
done

printf '\nAll runs complete.\n'
printf 'Inspect:\n'
printf '  %s/runs.csv\n' "$OUTDIR"
printf '  %s/samples.csv\n' "$OUTDIR"
