#!/usr/bin/env bash
# --- Run a foreground command on a spare VT without changing boot settings. ---
set -euo pipefail

function usage() {
  cat <<'EOF'
Usage: tty-ionice.sh [--dry-run] -- COMMAND [ARG ...]
       tty-ionice.sh --help

Switch to a free Linux console, run COMMAND as your normal user with
ionice -c 2 -n 0, then return to the previous console. Keep Hyprland and
SDDM running; never change systemd targets or service enablement.

Always request one build job per available CPU (nproc, ignoring OpenMP
thread limits). Cargo build commands, Make, Ninja and cmake --build have
their explicit job limits replaced. Child processes receive MAKEFLAGS,
CARGO_BUILD_JOBS, CMAKE_BUILD_PARALLEL_LEVEL and TTY_IONICE_JOBS.
Yay passes temporary assignments to makepkg after its configuration loads;
existing makepkg flags and configuration files are preserved. Yay --save
is rejected so these settings cannot be saved by this invocation.

Options:
  --dry-run  Print the command without sudo, execution, or switching consoles.
  --help     Show this help.

Examples:
  tty-ionice --dry-run -- cargo build --bins -j 2
  tty-ionice -- cargo build --bins
  tty-ionice -- yay -Syyu --noconfirm
  tty-ionice -- yay -S example --mflags '--nocheck'
  tty-ionice -- build-project -D "$HOME/src/project" --ninja
  tty-ionice -- cmake --build "$HOME/llvm-build" --parallel 2
  tty-ionice -- ninja -C "$HOME/llvm-build" -j 4
  tty-ionice -- make -C "$HOME/src/project" -j 1
  ./tty-ionice.sh -- bash -c 'printf "Console test\n"; sleep 5'

Run from a local desktop terminal as your normal user, not with sudo.
sudo is requested only to allocate the VT; the workload drops to your UID.
Working directory and PATH are preserved, but other custom environment
variables are not guaranteed. Use env NAME=value COMMAND when needed.
Commands must be executables (use bash -c or zsh -c for shell syntax).
Job arguments inside shell strings, env wrappers or unknown tools are not
rewritten. Such commands inherit the build environment but can override it.
Build dependencies and serial phases can leave CPUs idle. PKGBUILDs can
disable MAKEFLAGS or override job counts inside their build functions.
Dry runs use a placeholder for Yay's saved makepkg flags, read only on launch.
The workload exit status is returned. Ctrl+C on the new VT interrupts it.
Output appears on the VT. Use your command's logging options to retain it.
Hyprland applications remain in memory and may still perform background work.
The console workload is accessible to anyone physically at the keyboard.
The usual desktop idle lock can still engage. Ctrl+Alt+F1 returns to this
host's desktop manually if automatic return is interrupted.
Requires Linux, nproc (coreutils), sudo, openvt (kbd), and
ionice/runuser (util-linux). Yay also needs python3 to read saved flags.
EOF
}

function die() {
  printf 'tty-ionice: %s\n' "$*" >&2
  exit 1
}

function cpu_jobs() {
  local count
  count=$(/usr/bin/env -u OMP_NUM_THREADS -u OMP_THREAD_LIMIT \
    /usr/bin/nproc) || die 'Could not determine the available CPU count.'
  [[ $count =~ ^[1-9][0-9]*$ ]] || die 'nproc returned an invalid CPU count.'
  printf '%s\n' "$count"
}

# --- Rewrite options as arrays; never interpret arguments as shell code. ---
function force_make_assignment() {
  local -n assignment=$1
  local count=$2
  if [[ $assignment =~ ^((GNU)?MAKEFLAGS)([+:?]*|!)= ]]; then
    assignment="${BASH_REMATCH[1]}=-j$count"
  fi
}

function force_job_options() {
  local -n options=$1
  local kind=$2 count=$3 start=$4
  local index=$start argument prefix pattern
  local -a rewritten=("${options[@]:0:start}" -j "$count")
  if [[ $kind == cmake ]]; then
    rewritten=("${options[@]:0:start}" --parallel "$count")
  fi

  while ((index < ${#options[@]})); do
    argument=${options[index]}
    case "$argument" in
    --)
      if [[ $kind == cmake ]]; then
        local -a native_options=("${options[@]:index+1}")
        force_job_options native_options native "$count" 0
        rewritten+=(-- "${native_options[@]}")
      elif [[ $kind == make || $kind == native ]]; then
        # Make still interprets NAME=value assignments after --.
        rewritten+=(--)
        for argument in "${options[@]:index+1}"; do
          force_make_assignment argument "$count"
          rewritten+=("$argument")
        done
      else
        rewritten+=("${options[@]:index}")
      fi
      break
      ;;
    -j | --jobs | --parallel)
      # Make/CMake accept an omitted count; Cargo also accepts negatives/default.
      if ((index + 1 < ${#options[@]})) &&
        [[ ${options[index + 1]} =~ ^(-?[0-9]+|default)$ ]]; then
        ((index += 1))
      elif [[ $kind == cargo || $kind == ninja ]]; then
        die "Missing job count after $argument."
      fi
      ;;
    -j* | --jobs=* | --parallel=*) ;;
    MAKEFLAGS* | GNUMAKEFLAGS*)
      if [[ $kind == make || $kind == native ]]; then
        force_make_assignment argument "$count"
      fi
      rewritten+=("$argument")
      ;;
    *)
      # Keep values of options intact, even filenames that resemble -j options.
      case "$kind:$argument" in
      make:-[CfIoWE] | make:--directory | make:--file | make:--makefile | \
        make:--include-dir | make:--old-file | make:--assume-old | \
        make:--what-if | make:--new-file | make:--assume-new | make:--eval | \
        ninja:-[Cfdwkl] | native:-[CfIoWE] | \
        cargo:--bin | cargo:--example | cargo:--test | cargo:--bench | \
        cargo:--package | cargo:--exclude | cargo:--features | \
        cargo:--manifest-path | cargo:--target | cargo:--target-dir | \
        cargo:--artifact-dir | cargo:--profile | cargo:--color | \
        cargo:--message-format | cargo:--config | cargo:--git | \
        cargo:--branch | cargo:--tag | cargo:--rev | cargo:--path | \
        cargo:--root | cargo:--version | cargo:--index | cargo:--registry | \
        cargo:-[pFmZC] | cmake:--preset | cmake:--config | \
        cmake:--resolve-package-references)
        rewritten+=("$argument")
        ((index += 1))
        ((index < ${#options[@]})) || die "Missing value after $argument."
        rewritten+=("${options[index]}")
        ;;
      ninja:-t*)
        # A Ninja subtool owns all options after -t, including its own -j.
        rewritten+=("${options[@]:index}")
        break
        ;;
      *)
        # Common short-option clusters such as make -kj2 and cargo -vj2.
        pattern='^-[vqrfnhV]*j.*$'
        [[ $kind != ninja ]] || pattern='^-[nv]*j.*$'
        [[ $kind != make && $kind != native ]] ||
          pattern='^-[bBdehikmnpqrRsStvw]*j.*$'
        if [[ $argument =~ $pattern ]]; then
          prefix=${argument%%j*}
          [[ $prefix == - ]] || rewritten+=("$prefix")
          if [[ $argument == *j ]] && ((index + 1 < ${#options[@]})) &&
            [[ ${options[index + 1]} =~ ^(-?[0-9]+|default)$ ]]; then
            ((index += 1))
          fi
        else
          rewritten+=("$argument")
        fi
        ;;
      esac
      ;;
    esac
    ((index += 1))
  done
  options=("${rewritten[@]}")
}

# --- makepkg loads its configs before applying NAME=value arguments. ---
function force_yay_jobs() {
  local -n yay_options=$1
  local count=$2 preview=$3 argument original_flags='' explicit=false
  local index=1
  local -a rewritten=("${yay_options[0]}")
  while ((index < ${#yay_options[@]})); do
    argument=${yay_options[index]}
    case "$argument" in
    --)
      rewritten+=("${yay_options[@]:index}")
      break
      ;;
    --save | --save=*) die 'Yay --save would persist temporary job settings.' ;;
    --mflags | --mflags=*)
      "$explicit" && die 'Pass Yay --mflags only once.'
      explicit=true
      if [[ $argument == --mflags ]]; then
        ((index += 1))
        ((index < ${#yay_options[@]})) || die 'Missing Yay --mflags value.'
        original_flags=${yay_options[index]}
      else
        original_flags=${argument#*=}
      fi
      ;;
    *) rewritten+=("$argument") ;;
    esac
    ((index += 1))
  done

  if ! "$explicit"; then
    if "$preview"; then
      original_flags='<saved makepkg flags>'
    else
      [[ -x /usr/bin/python3 ]] || die 'Yay flag lookup needs /usr/bin/python3.'
      original_flags=$("${yay_options[0]}" -Pg | /usr/bin/python3 -c '
import json
import sys

flags = json.load(sys.stdin).get("mflags", "")
if not isinstance(flags, str):
  sys.exit("Yay mflags must be a string")
print(flags)
') || die 'Could not read Yay makepkg flags with yay -Pg.'
    fi
  fi
  if [[ $original_flags =~ (^|[[:space:]])--($|[[:space:]]) ]]; then
    die 'Yay --mflags must not contain the option terminator --.'
  fi
  local overrides="MAKEFLAGS=-j$count CARGO_BUILD_JOBS=$count"
  overrides+=" CMAKE_BUILD_PARALLEL_LEVEL=$count TTY_IONICE_JOBS=$count"
  yay_options=("${rewritten[0]}" --mflags
    "${original_flags:+$original_flags }$overrides" "${rewritten[@]:1}")
}

function prepare_command() {
  local -n command_options=$1
  local count=$2 preview=$3 program=${command_options[0]##*/} index
  case "$program" in
  make | gmake | ninja | ninja-build)
    local kind=make
    [[ $program != ninja* ]] || kind=ninja
    force_job_options "$1" "$kind" "$count" 1
    ;;
  cmake)
    if [[ ${command_options[1]:-} == --build ]]; then
      index=2
      if [[ -n ${command_options[2]:-} && ${command_options[2]} != -* ]]; then
        index=3
      fi
      force_job_options "$1" cmake "$count" "$index"
    fi
    ;;
  cargo)
    # Skip Cargo global options and an optional rustup +toolchain selector.
    index=1
    while ((index < ${#command_options[@]})); do
      case "${command_options[index]}" in
      --config | --color | -Z | -C) ((index += 2)) ;;
      +* | -*) ((index += 1)) ;;
      build | b | check | c | clippy | doc | d | rustc | rustdoc | run | r | \
        test | t | bench | install | fix)
        force_job_options "$1" cargo "$count" "$((index + 1))"
        break
        ;;
      *) break ;;
      esac
    done
    ;;
  yay) force_yay_jobs "$1" "$count" "$preview" ;;
  makepkg)
    # Final assignments beat config files and earlier command-line assignments.
    command_options+=("MAKEFLAGS=-j$count" "CARGO_BUILD_JOBS=$count"
      "CMAKE_BUILD_PARALLEL_LEVEL=$count" "TTY_IONICE_JOBS=$count")
    ;;
  esac
}

function main() {
  local preview=false
  while (($#)); do
    case "$1" in
    --help | -h)
      usage
      return 0
      ;;
    --dry-run)
      preview=true
      shift
      ;;
    --)
      shift
      break
      ;;
    *) die 'Expected -- before COMMAND; see --help.' ;;
    esac
  done
  (($#)) || die 'Missing command; see --help.'
  ((EUID != 0)) || die 'Run as your normal user, without sudo.'
  [[ -z ${SSH_CONNECTION:-} ]] || die 'Run from a local terminal, not SSH.'
  local workdir=$PWD count
  count=$(cpu_jobs)
  local -a command_args=("$@")
  prepare_command command_args "$count" "$preview"
  local -a workload=(/usr/bin/ionice -c 2 -n 0 -- /usr/bin/env
    -u GNUMAKEFLAGS -u MFLAGS -u CARGO_MAKEFLAGS
    "MAKEFLAGS=-j$count" "CARGO_BUILD_JOBS=$count"
    "CMAKE_BUILD_PARALLEL_LEVEL=$count" "TTY_IONICE_JOBS=$count"
    "${command_args[@]}")
  printf 'Working directory: %s\nParallel jobs: %s\nCommand:' "$workdir" "$count"
  printf ' %q' "${workload[@]}"
  printf '\n'
  if "$preview"; then
    return 0
  fi
  local program
  for program in sudo openvt runuser ionice bash mktemp; do
    [[ -x /usr/bin/$program ]] || die "Missing /usr/bin/$program."
  done
  [[ -t 0 && -t 1 ]] || die 'An interactive local terminal is required.'
  /usr/bin/sudo -v

  # --- openvt's status is not the workload status: record it as the user. ---
  result_dir=$(mktemp -d /tmp/tty-ionice.XXXXXXXX)
  trap 'rm -f -- "$result_dir/status"; rmdir -- "$result_dir"' EXIT
  local launch_status=0
  /usr/bin/sudo /usr/bin/openvt -s -w -- \
    /usr/bin/runuser -u "$(id -un)" -- \
    /usr/bin/env "PATH=$PATH" "XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}" \
    TERM=linux /usr/bin/bash -c '
    result=$1
    directory=$2
    shift 2
    function finish() {
      printf "%s\n" "$?" > "$result/status"
    }
    trap finish EXIT
    trap "exit 130" INT
    trap "exit 143" TERM
    trap "exit 129" HUP
    cd -- "$directory" || exit 1
    "$@"
    exit "$?"
  ' tty-ionice "$result_dir" "$workdir" "${workload[@]}" || launch_status=$?
  if ((launch_status != 0)); then
    die "Console launcher failed (status $launch_status)."
  fi
  [[ -s $result_dir/status ]] || die 'Workload status missing; check the console.'
  read -r status <"$result_dir/status"
  if [[ ! $status =~ ^[0-9]+$ ]] || ((status > 255)); then
    die 'Invalid workload status.'
  fi
  printf 'Workload exited with status %s.\n' "$status"
  exit "$status"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
