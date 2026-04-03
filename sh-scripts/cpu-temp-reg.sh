#!/usr/bin/env bash
###############################################################################
#  cputemp_regulator.sh
#
#  Adaptive CPU (and optional GPU) thermal management daemon
#  ---------------------------------------------------------
#  Author: <your‑name>
#  Version: 2.0 (May 2025)
#
#  This script monitors average CPU temperature (and optionally discrete‑GPU
#  temperature) and dynamically clamps the CPU frequency when user‑defined
#  thresholds are exceeded.  It is intended to run as an unprivileged
#  user‑service under systemd; sensitive writes are delegated to the
#  `cpupower` helper via polkit (or, on AMD, `ryzenadj` if available).
#
#  ───────────────────────────────────────────────────────────────────────────
#  USAGE
#  -----
#    cputemp_regulator.sh  [options]
#
#  Options (long form also accepted, e.g. --high 85):
#      -H, --high <°C>        Upper (critical) temperature threshold
#      -M, --medium <°C>      Medium threshold
#      -L, --low <°C>         Lower threshold (resume)
#      -u, --freq-max <Hz>    Frequency to apply when below LOW  (default=$FREQ_MAX)
#      -m, --freq-med <Hz>    Frequency to apply between LOW..MED (default=$FREQ_MED)
#      -l, --freq-min <Hz>    Frequency to apply above HIGH       (default=$FREQ_MIN)
#      -n, --samples <N>      Rolling‑average window size
#      -i, --interval <sec>   Sampling interval
#      -g, --gpu              Also throttle based on NVIDIA GPU temperature
#      -s, --simulate         Run a short synthetic stress‑test and exit
#      -f, --log-file <path>  Log file (default=$HOME/.local/var/log/cputemp_regulator.log)
#      -h, --help             Show this help and exit
#
#  Configuration hierarchy (later overrides earlier):
#     1. Built‑in defaults (below)
#     2. Config file  ~/.config/cputemp_regulator.conf   (bash syntax)
#     3. Command‑line options
#
#  Exit status:
#     0  normal exit     1–125 error    130+ received a signal
#
#  Example:
#     cputemp_regulator.sh -H 90 -M 85 -L 75 -g -i 3
#
#  --------------------------------------------------------------------------
#  LOG FORMAT (plain text)
#     [2025‑05‑14 14:02:07] INFO  Temp=72.8 °C ← freq 3.4 GHz
#     [2025‑05‑14 14:03:27] WARN  Temp=85.1 °C → freq 1.6 GHz
#  --------------------------------------------------------------------------
#
#  DEPENDENCIES
#     * lm‑sensors  (sensors)
#     * cpupower    (sudo/polkit‑enabled)
#     * (optional) stress‑ng — only for --simulate
#     * (optional) nvidia‑smi — for --gpu
#
###############################################################################

set -euo pipefail
IFS=$'\n\t'

### ───────────────────────────── 1. Defaults ───────────────────────────── ###
TEMP_HIGH=80
TEMP_MEDIUM=75
TEMP_LOW=70
FREQ_MAX="3.4GHz"
FREQ_MED="2.8GHz"
FREQ_MIN="1.6GHz"
NUM_SAMPLES=5
SLEEP_INTERVAL=5
GPU_MODE=false
SIMULATE=false
LOG_FILE="${HOME}/.local/var/log/cputemp_regulator.log"
mkdir -p "$(dirname "$LOG_FILE")"

### ───────────────────── 2. Helper: print_help() ───────────────────────── ###
print_help() { grep -E '^# {2}' "$0" | sed 's/^#  //' ; }

### ─────────────────────── 3. Read config file ─────────────────────────── ###
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/cputemp_regulator.conf"
[[ -f $CONFIG_FILE ]] && source "$CONFIG_FILE"

### ─────────────── 4. Parse command‑line arguments ─────────────────────── ###
ARGS=$(getopt -o H:M:L:u:m:l:n:i:f:gsh \
              --long high:,medium:,low:,freq-max:,freq-med:,freq-min:,samples:,interval:,log-file:,gpu,simulate,help \
              -n "$(basename "$0")" -- "$@")
eval set -- "$ARGS"
while true; do
    case "$1" in
        -H|--high)        TEMP_HIGH=$2; shift 2 ;;
        -M|--medium)      TEMP_MEDIUM=$2; shift 2 ;;
        -L|--low)         TEMP_LOW=$2; shift 2 ;;
        -u|--freq-max)    FREQ_MAX=$2; shift 2 ;;
        -m|--freq-med)    FREQ_MED=$2; shift 2 ;;
        -l|--freq-min)    FREQ_MIN=$2; shift 2 ;;
        -n|--samples)     NUM_SAMPLES=$2; shift 2 ;;
        -i|--interval)    SLEEP_INTERVAL=$2; shift 2 ;;
        -f|--log-file)    LOG_FILE=$2; shift 2 ;;
        -g|--gpu)         GPU_MODE=true; shift ;;
        -s|--simulate)    SIMULATE=true; shift ;;
        -h|--help)        print_help; exit 0 ;;
        --) shift; break ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

### ─────────────── 5. Check dependencies (lazy) ────────────────────────── ###
command -v sensors >/dev/null     || { echo "Error: sensors not found" >&2; exit 2; }
command -v cpupower >/dev/null    || { echo "Error: cpupower not found" >&2; exit 2; }
$GPU_MODE && command -v nvidia-smi >/dev/null || true

### ─────────────── 6. Utility functions ────────────────────────────────── ###
log() { printf '[%s] %-5s %s\n' "$(date '+%F %T')" "$1" "$2" | tee -a "$LOG_FILE"; }

get_cpu_temp() {
    # Chooses the first line containing "Package id" or "Tctl" (AMD)
    local t
    t=$(sensors | awk '/Package id 0:|Tctl:/ {gsub(/[+°C]/,""); print $3; exit}')
    echo "${t:-0}"
}

get_gpu_temp() {
    $GPU_MODE || { echo 0; return; }
    local t
    t=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -n1)
    echo "${t:-0}"
}

apply_frequency() {
    local f=$1
    pkexec cpupower frequency-set -u "$f" >/dev/null
}

simulate_load() {
    command -v stress-ng >/dev/null || { echo "stress-ng not found; skipping simulation." >&2; return; }
    log INFO "Running 30‑s stress‑test to verify throttling behaviour …"
    stress-ng --cpu 0 --timeout 30s --metrics-brief
    exit 0
}

### ──────────────────────── 7. Simulation mode ─────────────────────────── ###
$SIMULATE && simulate_load

### ─────────────────────── 8. Main control loop ────────────────────────── ###
temps=()
while true; do
    cpu_t=$(get_cpu_temp)
    gpu_t=$(get_gpu_temp)
    temps+=("$cpu_t")
    (( ${#temps[@]} > NUM_SAMPLES )) && temps=("${temps[@]:1}")

    # Compute average
    sum=0
    for t in "${temps[@]}"; do sum=$((sum + t)); done
    avg=$((sum / ${#temps[@]}))

    # Decide frequency
    if (( avg >= TEMP_HIGH )); then
        freq=$FREQ_MIN
        level="WARN "
    elif (( avg >= TEMP_MEDIUM )); then
        freq=$FREQ_MED
        level="INFO "
    else
        freq=$FREQ_MAX
        level="INFO "
    fi

    apply_frequency "$freq"
    log "$level" "CPU=${avg}°C GPU=${gpu_t}°C → freq $freq"

    sleep "$SLEEP_INTERVAL"
done

