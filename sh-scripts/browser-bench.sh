#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# browser-bench.sh
#
# Systematic browser benchmarking logger (CPU + RSS, optional temperature).
#
# QUICK START
#   ./browser-bench.sh all \
#     --browsers "chromium=chromium,thorium=thorium-browser-avx2" \
#     --outroot "$HOME/browsers"
#
# What this does:
#   - Balanced randomized trial order per (session × scenario), across browsers.
#   - Isolated profile per trial (reduces cache carryover).
#   - Appends raw samples + per-trial summaries + per-session summaries to CSVs.
#   - Optional Hyprland "low effects" mode (automatic apply + automatic restore).
#
# What this does NOT do:
#   - Auto-click benchmarks (you click "Start Test" after warmup).
#
# Output layout (default OUTROOT=$HOME/browsers):
#   $OUTROOT/samples.csv   (raw time series, per sample)
#   $OUTROOT/trials.csv    (per-trial summary)
#   $OUTROOT/sessions.csv  (per-session aggregates)
#   $OUTROOT/<browser>/... (mirrors of the same three CSVs)
#
# Dependencies:
#   Required: python, ps, awk, sort
#   Optional: hyprctl (only for --hypr-mode low)
# =============================================================================

function usage() {
  cat <<'USAGE_EOF'
Usage:
  browser-bench.sh all
    [--browsers  "chromium=chromium,thorium=thorium-browser-avx2"]
    [--scenarios "idle,speedometer,jetstream,motionmark,youtube"]
    [--sessions  N]
    [--trials    N]
    [--interval  SEC]
    [--seed      INT]
    [--outroot   DIR]
    [--hypr-mode keep|low]
    [--no-temp]
  browser-bench.sh --help

Notes (important):
  - For Speedometer / JetStream / MotionMark you must click "Start Test"
    yourself. Do so immediately after the warmup ends.
  - Trial order is randomized but balanced across browsers, to reduce drift
    confounds (temperature, daemon activity, power state).
  - Each trial uses a fresh isolated browser profile directory.

Defaults:
  --browsers   auto-detect: chromium + thorium-browser-avx2 if available
  --scenarios  idle,speedometer,jetstream,motionmark,youtube
  --sessions   1
  --trials     5        (per browser, per scenario, per session)
  --interval   1        (seconds between samples)
  --seed       unset    (true random)
  --outroot    $HOME/browsers
  --hypr-mode  keep
  --no-temp    off      (temperature logging enabled if available)

Examples:
  1) Chromium vs Thorium AVX2:
     ./browser-bench.sh all \
       --browsers "chromium=chromium,thorium=thorium-browser-avx2"

  2) Quick run, fewer scenarios:
     ./browser-bench.sh all \
       --browsers "chromium=chromium,thorium=thorium-browser-avx2" \
       --scenarios "idle,speedometer,jetstream" \
       --trials 3 --sessions 1

  3) Reproducible randomization:
     ./browser-bench.sh all --seed 12345

  4) Run while Hyprland effects are reduced (automatic apply + restore):
     ./browser-bench.sh all --hypr-mode low

Hyprland low mode behaviour:
  --hypr-mode low automatically runs:
    animations:enabled        = 0
    decoration:blur:enabled   = 0
    decoration:shadow:enabled = 0
    misc:vfr                  = 1
  It also captures your previous values and restores them on exit.
USAGE_EOF
}

function die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

function require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"
}

function now_iso()   { date -Is; }
function tz_name()   { date +%Z; }
function date_ymd()  { date +%F; }
function time_hms()  { date +%T; }

function read_load1() {
  awk '{print $1}' /proc/loadavg 2>/dev/null || echo ""
}

function count_processes() {
  ps -e --no-headers 2>/dev/null | wc -l | awk '{print $1}'
}

function count_running_services() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl list-units --type=service --state=running --no-legend 2>/dev/null \
      | wc -l | awk '{print $1}'
  else
    echo ""
  fi
}

function read_temp_c() {
  # Reads max thermal zone temp if available. Returns "" if not.
  local max_mc=""
  local z t
  for z in /sys/class/thermal/thermal_zone*/temp; do
    [[ -r "$z" ]] || continue
    t="$(cat "$z" 2>/dev/null || true)"
    [[ "$t" =~ ^[0-9]+$ ]] || continue
    if [[ -z "$max_mc" || "$t" -gt "$max_mc" ]]; then
      max_mc="$t"
    fi
  done
  [[ -n "$max_mc" ]] || { echo ""; return 0; }
  awk -v mc="$max_mc" 'BEGIN{printf "%.1f", mc/1000.0}'
}

function read_proc_jiffies_total() {
  awk 'NR==1 && $1=="cpu"{s=0; for(i=2;i<=NF;i++) s+=$i; print s}' /proc/stat
}

function read_proc_jiffies_pid() {
  local pid="$1"
  awk '{print $14+$15}' "/proc/${pid}/stat" 2>/dev/null || echo 0
}

function read_rss_kb_pid() {
  local pid="$1"
  awk '$1=="VmRSS:"{print $2}' "/proc/${pid}/status" 2>/dev/null || echo 0
}

function list_tree_pids() {
  local root_pid="$1"
  local -a queue
  local -A seen
  queue=("$root_pid")
  seen["$root_pid"]=1

  while ((${#queue[@]} > 0)); do
    local pid="${queue[0]}"
    queue=("${queue[@]:1}")
    printf '%s\n' "$pid"

    while IFS= read -r child; do
      [[ -z "$child" ]] && continue
      if [[ -z "${seen[$child]:-}" ]]; then
        seen["$child"]=1
        queue+=("$child")
      fi
    done < <(ps -o pid= --ppid "$pid" 2>/dev/null | awk '{print $1}')
  done
}

function sum_rss_kb_tree() {
  local root_pid="$1"
  local sum=0 pid rss
  while IFS= read -r pid; do
    rss="$(read_rss_kb_pid "$pid")"
    sum=$((sum + rss))
  done < <(list_tree_pids "$root_pid")
  printf '%s' "$sum"
}

function sum_jiffies_tree() {
  local root_pid="$1"
  local sum=0 pid j
  while IFS= read -r pid; do
    j="$(read_proc_jiffies_pid "$pid")"
    sum=$((sum + j))
  done < <(list_tree_pids "$root_pid")
  printf '%s' "$sum"
}

function cpu_pct_from_deltas() {
  local dproc="$1" dtot="$2"
  awk -v a="$dproc" -v b="$dtot" 'BEGIN{
    if (b<=0) {print 0; exit}
    printf "%.3f", (100.0*a)/b
  }'
}

function median_col_csv() {
  local file="$1" col="$2"
  awk -F',' -v c="$col" 'NR>1{print $c}' "$file" | sort -n | awk '
    {a[NR]=$1}
    END{
      if(NR==0){print ""; exit}
      if(NR%2==1){print a[(NR+1)/2]}
      else{print (a[NR/2]+a[NR/2+1])/2}
    }'
}

function min_col_csv() {
  local file="$1" col="$2"
  awk -F',' -v c="$col" 'NR>1{if($c<m||NR==2)m=$c} END{print m}' "$file"
}

function max_col_csv() {
  local file="$1" col="$2"
  awk -F',' -v c="$col" 'NR>1{if($c>m||NR==2)m=$c} END{print m}' "$file"
}

function ensure_csv_headers() {
  local outroot="$1"
  local samples="$outroot/samples.csv"
  local trials="$outroot/trials.csv"
  local sessions="$outroot/sessions.csv"

  if [[ ! -f "$samples" ]]; then
    printf 'ts_iso,date,time,tz,session_id,session_index,scenario,url,' \
      >"$samples"
    printf 'browser,cmd,hypr_mode,trial_global,trial_in_session,iteration,' \
      >>"$samples"
    printf 'sample_idx,rss_kb,cpu_pct,temp_c\n' \
      >>"$samples"
  fi

  if [[ ! -f "$trials" ]]; then
    printf 'session_id,session_index,scenario,url,browser,cmd,hypr_mode,' \
      >"$trials"
    printf 'trial_global,trial_in_session,iteration,start_ts,end_ts,' \
      >>"$trials"
    printf 'duration_sec,interval_sec,warmup_sec,samples,' \
      >>"$trials"
    printf 'rss_med_kb,rss_min_kb,rss_max_kb,cpu_med_pct,cpu_min_pct,' \
      >>"$trials"
    printf 'cpu_max_pct,temp_before_c,temp_after_c,load1_before,load1_after,' \
      >>"$trials"
    printf 'procs_before,procs_after,services_before,services_after\n' \
      >>"$trials"
  fi

  if [[ ! -f "$sessions" ]]; then
    printf 'session_id,session_index,scenario,browser,trials,' \
      >"$sessions"
    printf 'rss_med_of_meds_kb,cpu_med_of_meds_pct,started_ts,ended_ts\n' \
      >>"$sessions"
  fi
}

function mirror_paths() {
  local outroot="$1" browser="$2"
  local bdir="$outroot/$browser"
  mkdir -p "$bdir"
  ensure_csv_headers "$bdir"
  printf '%s' "$bdir"
}

function detect_default_browsers() {
  local list=()
  if command -v chromium >/dev/null 2>&1; then
    list+=("chromium=chromium")
  fi
  if command -v thorium-browser-avx2 >/dev/null 2>&1; then
    list+=("thorium=thorium-browser-avx2")
  elif command -v thorium-browser >/dev/null 2>&1; then
    list+=("thorium=thorium-browser")
  elif command -v thorium >/dev/null 2>&1; then
    list+=("thorium=thorium")
  fi
  ((${#list[@]} > 0)) || die "No browsers detected. Use --browsers."
  local IFS=,
  echo "${list[*]}"
}

function parse_browsers() {
  local raw="$1"
  declare -g -a B_NAMES=()
  declare -g -a B_CMDS=()

  local IFS=,
  local item
  for item in $raw; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "$item" ]] || continue
    if [[ "$item" == *"="* ]]; then
      B_NAMES+=("${item%%=*}")
      B_CMDS+=("${item#*=}")
    else
      B_NAMES+=("$(basename "${item%% *}")")
      B_CMDS+=("$item")
    fi
  done
  ((${#B_NAMES[@]} > 0)) || die "No valid browsers parsed."
}

function scenario_defaults() {
  declare -g -A SCEN_URL=()
  declare -g -A SCEN_DUR=()
  declare -g -A SCEN_WARM=()

  SCEN_URL["idle"]="about:blank"
  SCEN_DUR["idle"]=120
  SCEN_WARM["idle"]=5

  SCEN_URL["speedometer"]="https://browserbench.org/Speedometer3.0/"
  SCEN_DUR["speedometer"]=600
  SCEN_WARM["speedometer"]=10

  SCEN_URL["jetstream"]="https://browserbench.org/JetStream2.0/"
  SCEN_DUR["jetstream"]=600
  SCEN_WARM["jetstream"]=10

  SCEN_URL["motionmark"]="https://browserbench.org/MotionMark1.3/"
  SCEN_DUR["motionmark"]=420
  SCEN_WARM["motionmark"]=10

  SCEN_URL["youtube"]="https://www.youtube.com/watch?v=dQw4w9WgXcQ"
  SCEN_DUR["youtube"]=180
  SCEN_WARM["youtube"]=10
}

function get_next_session_index() {
  local outroot="$1"
  local sessions="$outroot/sessions.csv"
  if [[ ! -f "$sessions" ]]; then
    echo 1
    return 0
  fi
  local last
  last="$(awk -F',' 'NR>1{v=$2} END{print v}' "$sessions" 2>/dev/null || true)"
  [[ -n "$last" ]] || { echo 1; return 0; }
  echo $((last + 1))
}

function hypr_get_int() {
  local key="$1"
  command -v hyprctl >/dev/null 2>&1 || { echo ""; return 0; }

  local out
  out="$(hyprctl getoption "$key" -j 2>/dev/null || true)"
  [[ -n "$out" ]] || { echo ""; return 0; }

  python - <<'PY' <<<"$out" 2>/dev/null || true
import json,sys
j=json.load(sys.stdin)
v=j.get("int", j.get("float", ""))
print(v)
PY
}

function hypr_apply_low_mode() {
  command -v hyprctl >/dev/null 2>&1 || return 0
  hyprctl --batch "\
keyword animations:enabled 0; \
keyword decoration:blur:enabled 0; \
keyword decoration:shadow:enabled 0; \
keyword misc:vfr 1" >/dev/null 2>&1 || true
}

function hypr_apply_values() {
  command -v hyprctl >/dev/null 2>&1 || return 0
  local anim="$1" blur="$2" shad="$3" vfr="$4"
  hyprctl --batch "\
keyword animations:enabled ${anim}; \
keyword decoration:blur:enabled ${blur}; \
keyword decoration:shadow:enabled ${shad}; \
keyword misc:vfr ${vfr}" >/dev/null 2>&1 || true
}

function run_trial() {
  local outroot="$1" bname="$2" bcmd="$3" scen="$4" hypr_mode="$5"
  local session_id="$6" session_idx="$7" trial_global="$8"
  local trial_in_session="$9" iteration="${10}"
  local interval="${11}" no_temp="${12}"

  local url="${SCEN_URL[$scen]}"
  local dur="${SCEN_DUR[$scen]}"
  local warm="${SCEN_WARM[$scen]}"

  local start_ts end_ts tz temp_b temp_a load_b load_a procs_b procs_a
  local svcs_b svcs_a

  start_ts="$(now_iso)"
  tz="$(tz_name)"

  load_b="$(read_load1)"
  procs_b="$(count_processes)"
  svcs_b="$(count_running_services)"
  if [[ "$no_temp" == "0" ]]; then
    temp_b="$(read_temp_c)"
  else
    temp_b=""
  fi

  local profile_dir
  profile_dir="$(mktemp -d -p "$outroot" "profile.${bname}.${scen}.XXXXXXXX")"

  set +e
  "$bcmd" \
    --user-data-dir="$profile_dir" \
    --no-first-run \
    --disable-sync \
    --disable-background-networking \
    "$url" >/dev/null 2>&1 &
  set -e
  local root_pid="$!"
  sleep 0.3
  kill -0 "$root_pid" 2>/dev/null || die "Browser did not start: $bcmd"

  printf '\nSession %s | Scenario %s | %s (iter %s) | Trial %s (order %s)\n' \
    "$session_idx" "$scen" "$bname" "$iteration" "$trial_global" \
    "$trial_in_session"
  printf 'Warmup %ss then sample %ss every %ss. Click benchmark start after warmup.\n' \
    "$warm" "$dur" "$interval"

  if ((warm > 0)); then
    sleep "$warm"
  fi

  local tmp
  tmp="$(mktemp -p "$outroot" "trial.${session_id}.${trial_global}.XXXXXXXX.csv")"
  printf 'ts_iso,date,time,tz,session_id,session_index,scenario,url,' \
    >"$tmp"
  printf 'browser,cmd,hypr_mode,trial_global,trial_in_session,iteration,' \
    >>"$tmp"
  printf 'sample_idx,rss_kb,cpu_pct,temp_c\n' \
    >>"$tmp"

  local prev_tot prev_proc
  prev_tot="$(read_proc_jiffies_total)"
  prev_proc="$(sum_jiffies_tree "$root_pid")"

  local sample_idx=0 elapsed=0
  while ((elapsed < dur)); do
    kill -0 "$root_pid" 2>/dev/null || break
    sleep "$interval"
    elapsed=$((elapsed + interval))
    sample_idx=$((sample_idx + 1))

    local cur_tot cur_proc d_tot d_proc cpu_pct rss_kb temp_c
    cur_tot="$(read_proc_jiffies_total)"
    cur_proc="$(sum_jiffies_tree "$root_pid")"
    d_tot=$((cur_tot - prev_tot))
    d_proc=$((cur_proc - prev_proc))
    cpu_pct="$(cpu_pct_from_deltas "$d_proc" "$d_tot")"
    rss_kb="$(sum_rss_kb_tree "$root_pid")"
    if [[ "$no_temp" == "0" ]]; then
      temp_c="$(read_temp_c)"
    else
      temp_c=""
    fi

    printf '%s,%s,%s,%s,%s,%s,%s,%s,' \
      "$(now_iso)" "$(date_ymd)" "$(time_hms)" "$tz" "$session_id" "$session_idx" \
      "$scen" "$url" >>"$tmp"
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$bname" "$bcmd" "$hypr_mode" "$trial_global" "$trial_in_session" \
      "$iteration" "$sample_idx" "$rss_kb" "$cpu_pct" "$temp_c" >>"$tmp"

    prev_tot="$cur_tot"
    prev_proc="$cur_proc"
  done

  kill -TERM "$root_pid" 2>/dev/null || true
  sleep 0.5
  kill -KILL "$root_pid" 2>/dev/null || true

  end_ts="$(now_iso)"
  load_a="$(read_load1)"
  procs_a="$(count_processes)"
  svcs_a="$(count_running_services)"
  if [[ "$no_temp" == "0" ]]; then
    temp_a="$(read_temp_c)"
  else
    temp_a=""
  fi

  # tmp columns:
  # 16=rss_kb, 17=cpu_pct, 18=temp_c
  local nsamp rss_med rss_min rss_max cpu_med cpu_min cpu_max
  nsamp="$(awk 'END{print NR-1}' "$tmp")"
  rss_med="$(median_col_csv "$tmp" 16)"
  rss_min="$(min_col_csv    "$tmp" 16)"
  rss_max="$(max_col_csv    "$tmp" 16)"
  cpu_med="$(median_col_csv "$tmp" 17)"
  cpu_min="$(min_col_csv    "$tmp" 17)"
  cpu_max="$(max_col_csv    "$tmp" 17)"

  ensure_csv_headers "$outroot"
  cat "$tmp" >>"$outroot/samples.csv"

  local bdir
  bdir="$(mirror_paths "$outroot" "$bname")"
  cat "$tmp" >>"$bdir/samples.csv"

  # trials.csv columns are fixed by ensure_csv_headers() above.
  printf '%s,%s,%s,%s,%s,%s,%s,' \
    "$session_id" "$session_idx" "$scen" "$url" "$bname" "$bcmd" \
    "$hypr_mode" >>"$outroot/trials.csv"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,' \
    "$trial_global" "$trial_in_session" "$iteration" "$start_ts" "$end_ts" \
    "${SCEN_DUR[$scen]}" "$interval" "${SCEN_WARM[$scen]}" "$nsamp" \
    >>"$outroot/trials.csv"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$rss_med" "$rss_min" "$rss_max" \
    "$cpu_med" "$cpu_min" "$cpu_max" \
    "$temp_b" "$temp_a" \
    "$load_b" "$load_a" \
    "$procs_b" "$procs_a" \
    "$svcs_b" "$svcs_a" \
    >>"$outroot/trials.csv"

  printf '%s,%s,%s,%s,%s,%s,%s,' \
    "$session_id" "$session_idx" "$scen" "$url" "$bname" "$bcmd" \
    "$hypr_mode" >>"$bdir/trials.csv"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,' \
    "$trial_global" "$trial_in_session" "$iteration" "$start_ts" "$end_ts" \
    "${SCEN_DUR[$scen]}" "$interval" "${SCEN_WARM[$scen]}" "$nsamp" \
    >>"$bdir/trials.csv"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$rss_med" "$rss_min" "$rss_max" \
    "$cpu_med" "$cpu_min" "$cpu_max" \
    "$temp_b" "$temp_a" \
    "$load_b" "$load_a" \
    "$procs_b" "$procs_a" \
    "$svcs_b" "$svcs_a" \
    >>"$bdir/trials.csv"

  rm -rf -- "$profile_dir"
  rm -f -- "$tmp"

  printf '  -> appended to %s/{samples.csv,trials.csv}\n' "$outroot"
}

function write_session_summaries() {
  local outroot="$1" session_id="$2" session_idx="$3"
  local trials="$outroot/trials.csv"
  [[ -f "$trials" ]] || return 0

  # trials.csv columns:
  #  1 session_id
  #  2 session_index
  #  3 scenario
  #  5 browser
  # 11 start_ts
  # 12 end_ts
  # 17 rss_med_kb
  # 20 cpu_med_pct
  awk -F',' -v sid="$session_id" -v sidx="$session_idx" '
    BEGIN{OFS=","}
    NR==1{next}
    $1==sid && $2==sidx{
      scen=$3; brow=$5
      key=scen SUBSEP brow
      n[key]++
      rss[key,n[key]]=$17+0
      cpu[key,n[key]]=$20+0
      st[key]=$11
      en[key]=$12
    }
    END{
      for (k in n){
        split(k, a, SUBSEP); scen=a[1]; brow=a[2]
        m=n[k]
        delete vr; delete vc
        for(i=1;i<=m;i++){ vr[i]=rss[k,i]; vc[i]=cpu[k,i] }
        asort(vr); asort(vc)
        if(m%2==1){ mr=vr[(m+1)/2]; mc=vc[(m+1)/2] }
        else { mr=(vr[m/2]+vr[m/2+1])/2; mc=(vc[m/2]+vc[m/2+1])/2 }
        print sid, sidx, scen, brow, m, mr, mc, st[k], en[k]
      }
    }' "$trials" >>"$outroot/sessions.csv"

  local bi
  for ((bi=0; bi<${#B_NAMES[@]}; bi++)); do
    local bname="${B_NAMES[$bi]}"
    local bdir="$outroot/$bname"
    [[ -d "$bdir" ]] || continue
    awk -F',' -v sid="$session_id" -v sidx="$session_idx" -v bn="$bname" '
      BEGIN{OFS=","}
      NR==1{next}
      $1==sid && $2==sidx && $5==bn{
        scen=$3; brow=$5
        key=scen SUBSEP brow
        n[key]++
        rss[key,n[key]]=$17+0
        cpu[key,n[key]]=$20+0
        st[key]=$11
        en[key]=$12
      }
      END{
        for (k in n){
          split(k, a, SUBSEP); scen=a[1]; brow=a[2]
          m=n[k]
          delete vr; delete vc
          for(i=1;i<=m;i++){ vr[i]=rss[k,i]; vc[i]=cpu[k,i] }
          asort(vr); asort(vc)
          if(m%2==1){ mr=vr[(m+1)/2]; mc=vc[(m+1)/2] }
          else { mr=(vr[m/2]+vr[m/2+1])/2; mc=(vc[m/2]+vc[m/2+1])/2 }
          print sid, sidx, scen, brow, m, mr, mc, st[k], en[k]
        }
      }' "$trials" >>"$bdir/sessions.csv"
  done
}

function shuffle_pairs() {
  # Prints lines: "bidx iteration trial_in_session"
  local nb="$1" nt="$2" seed="${3:-}"
  python - "$nb" "$nt" "${seed:-}" <<'PY'
import os, random, sys
nb=int(sys.argv[1]); nt=int(sys.argv[2]); seed=sys.argv[3]
pairs=[]
for b in range(nb):
  for i in range(1, nt+1):
    pairs.append((b, i))
if seed:
  random.seed(int(seed))
else:
  random.seed(os.urandom(32))
random.shuffle(pairs)
for j,(b,i) in enumerate(pairs, start=1):
  print(b, i, j)
PY
}

function cmd_all() {
  local browsers_raw="$1" scenarios_raw="$2" sessions="$3" trials="$4"
  local interval="$5" seed="${6:-}" outroot="$7" hypr_mode="$8" no_temp="$9"

  scenario_defaults
  mkdir -p "$outroot"
  ensure_csv_headers "$outroot"

  parse_browsers "$browsers_raw"

  local session_idx
  session_idx="$(get_next_session_index "$outroot")"

  local hypr_anim="" hypr_blur="" hypr_shad="" hypr_vfr=""
  if [[ "$hypr_mode" == "low" ]]; then
    hypr_anim="$(hypr_get_int "animations:enabled")"
    hypr_blur="$(hypr_get_int "decoration:blur:enabled")"
    hypr_shad="$(hypr_get_int "decoration:shadow:enabled")"
    hypr_vfr="$(hypr_get_int "misc:vfr")"
    hypr_apply_low_mode
    trap 'hypr_apply_values "${hypr_anim:-1}" "${hypr_blur:-1}" \
      "${hypr_shad:-1}" "${hypr_vfr:-1}"' EXIT
  fi

  local s
  local IFS=,
  for ((sess=1; sess<=sessions; sess++)); do
    local session_id
    session_id="$(date +%Y%m%d-%H%M%S)-${session_idx}"

    printf '\n============================================================\n'
    printf 'SESSION %s  (session_id=%s)\n' "$session_idx" "$session_id"
    printf 'Browsers:  %s\n' "$browsers_raw"
    printf 'Scenarios: %s\n' "$scenarios_raw"
    printf 'Trials:    %s per browser per scenario\n' "$trials"
    printf 'Interval:  %ss\n' "$interval"
    printf 'Hypr mode: %s\n' "$hypr_mode"
    printf 'Temp log:  %s\n' "$([[ "$no_temp" == "1" ]] && echo "disabled" || echo "enabled")"
    printf '============================================================\n'

    for s in $scenarios_raw; do
      [[ -n "${SCEN_URL[$s]:-}" ]] || die "Unknown scenario: $s"

      # trial_global is column 8 in trials.csv
      local trial_global_start
      trial_global_start="$(awk -F',' 'NR>1{v=$8} END{print v+0}' \
        "$outroot/trials.csv" 2>/dev/null || echo 0)"
      local trial_global="$trial_global_start"

      while IFS=$' \t' read -r bidx iter order; do
        trial_global=$((trial_global + 1))
        run_trial "$outroot" "${B_NAMES[$bidx]}" "${B_CMDS[$bidx]}" \
          "$s" "$hypr_mode" "$session_id" "$session_idx" \
          "$trial_global" "$order" "$iter" "$interval" "$no_temp"
      done < <(shuffle_pairs "${#B_NAMES[@]}" "$trials" "${seed:-}")
    done

    write_session_summaries "$outroot" "$session_id" "$session_idx"
    session_idx=$((session_idx + 1))
  done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
require_cmd ps
require_cmd awk
require_cmd sort
require_cmd python

SUBCMD="${1:-}"
shift || true

if [[ -z "$SUBCMD" || "$SUBCMD" == "-h" || "$SUBCMD" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$SUBCMD" != "all" ]]; then
  die "Only subcommand supported: all"
fi

BROWSERS_RAW=""
SCENARIOS_RAW="idle,speedometer,jetstream,motionmark,youtube"
SESSIONS=1
TRIALS=5
INTERVAL=1
SEED=""
OUTROOT="${HOME}/browsers"
HYPR_MODE="keep"
NO_TEMP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --browsers)   BROWSERS_RAW="${2:-}"; shift 2 ;;
    --scenarios)  SCENARIOS_RAW="${2:-}"; shift 2 ;;
    --sessions)   SESSIONS="${2:-}"; shift 2 ;;
    --trials)     TRIALS="${2:-}"; shift 2 ;;
    --interval)   INTERVAL="${2:-}"; shift 2 ;;
    --seed)       SEED="${2:-}"; shift 2 ;;
    --outroot)    OUTROOT="${2:-}"; shift 2 ;;
    --hypr-mode)  HYPR_MODE="${2:-}"; shift 2 ;;
    --no-temp)    NO_TEMP=1; shift 1 ;;
    -h|--help)    usage; exit 0 ;;
    *) die "Unknown arg: $1" ;;
  esac
done

[[ "$SESSIONS" =~ ^[0-9]+$ ]] || die "--sessions must be integer"
[[ "$TRIALS" =~ ^[0-9]+$   ]] || die "--trials must be integer"
[[ "$INTERVAL" =~ ^[0-9]+$ ]] || die "--interval must be integer"
((INTERVAL >= 1)) || die "--interval must be >= 1"
[[ "$HYPR_MODE" == "keep" || "$HYPR_MODE" == "low" ]] \
  || die "--hypr-mode must be keep|low"

if [[ -z "$BROWSERS_RAW" ]]; then
  BROWSERS_RAW="$(detect_default_browsers)"
fi

cmd_all "$BROWSERS_RAW" "$SCENARIOS_RAW" "$SESSIONS" "$TRIALS" \
  "$INTERVAL" "${SEED:-}" "$OUTROOT" "$HYPR_MODE" "$NO_TEMP"
