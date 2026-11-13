#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# codex-exec-capture
# Save the documented codex exec --json event stream as JSON Lines.
# -----------------------------------------------------------------------------

set -Eeuo pipefail
umask 077

readonly PROGRAM="${0##*/}"
if [[ -n "${CODEX_CAPTURE_DIR:-}" ]]; then
  output_root="$CODEX_CAPTURE_DIR"
else
  state_root="${XDG_STATE_HOME:-${HOME}/.local/state}"
  output_root="${state_root}/codex-capture"
fi
session_label="exec"
reasoning_mode="best"
declare -a codex_args=()

function show_help()
{
  cat << EOF
Usage:
  ${PROGRAM} [CAPTURE OPTIONS] -- CODEX-EXEC OPTIONS... PROMPT

Run codex exec --json and save its JSONL event stream. Unlike terminal capture,
this produces structured events for reasoning, commands, file changes, MCP tool
calls, web searches, plans, and agent messages.

Capture options:
      --dir DIRECTORY         Root directory for captured sessions
      --name LABEL            Add a short label to the session directory
      --configured-reasoning  Preserve reasoning-display configuration
  -h, --help                  Show this help

Examples:
  ${PROGRAM} -- "summarize this repository"
  ${PROGRAM} --name tests -- --sandbox workspace-write \\
    "run the tests, diagnose failures, and fix them"
EOF
}

function die()
{
  printf '%s: error: %s\n' "$PROGRAM" "$*" >&2
  exit 1
}

function sanitize_label()
{
  local value="$1"

  value="${value// /-}"
  value="$(printf '%s' "$value" | tr -cs '[:alnum:]_.-' '-')"
  value="${value#-}"
  value="${value%-}"
  printf '%.48s' "$value"
}

function quote_command()
{
  local argument
  local -a quoted=()

  for argument in "$@"; do
    printf -v argument '%q' "$argument"
    quoted+=("$argument")
  done
  printf '%s' "${quoted[*]}"
}

while (($# > 0)); do
  case "$1" in
    --dir)
      [[ -n "${2:-}" ]] || die "--dir requires a value"
      output_root="$2"
      shift
      ;;
    --name)
      [[ -n "${2:-}" ]] || die "--name requires a value"
      session_label="$2"
      shift
      ;;
    --configured-reasoning)
      reasoning_mode="configured"
      ;;
    -h | --help)
      show_help
      exit 0
      ;;
    --)
      shift
      codex_args=("$@")
      break
      ;;
    *)
      die "unknown capture option '$1'; place Codex arguments after --"
      ;;
  esac
  shift
done

((${#codex_args[@]} > 0)) || die "a Codex prompt or exec argument is required"
command -v codex > /dev/null 2>&1 || die "codex is not installed"

install -d -m 700 -- "$output_root"
timestamp="$(date '+%Y-%m-%d_%H-%M-%S')"
label="$(sanitize_label "$session_label")"
session_dir="${output_root}/${timestamp}_${label}_${BASHPID}"
install -d -m 700 -- "$session_dir"
ln -sfn -- "$session_dir" "${output_root}/latest"

declare -a command_line=(codex)

if [[ "$reasoning_mode" == best ]]; then
  command_line+=(
    --config 'hide_agent_reasoning=false'
    --config 'show_raw_agent_reasoning=true'
    --config 'model_reasoning_summary="detailed"'
  )
fi

command_line+=(exec --json "${codex_args[@]}")

{
  printf 'format_version=%q\n' '1'
  printf 'started_at=%q\n' "$(date --iso-8601=seconds)"
  printf 'working_directory=%q\n' "$PWD"
  printf 'codex_command=%q\n' "$(quote_command "${command_line[@]}")"
  printf 'reasoning_capture=%q\n' "$reasoning_mode"
} > "${session_dir}/session.meta"

printf 'Structured event capture:\n  %s\n\n' "$session_dir" >&2

set +e
"${command_line[@]}" \
  2> >(tee "${session_dir}/stderr.log" >&2) \
  | tee "${session_dir}/events.jsonl"
pipeline_status=("${PIPESTATUS[@]}")
set -e

codex_status="${pipeline_status[0]}"
tee_status="${pipeline_status[1]}"

if command -v jq > /dev/null 2>&1 \
  && [[ -s "${session_dir}/events.jsonl" ]]; then
  jq -sr '
    [
      .[]
      | select(
          .type == "item.completed"
          and .item.type == "agent_message"
        )
      | .item.text
    ]
    | last // empty
  ' "${session_dir}/events.jsonl" > "${session_dir}/final-message.md" || true
fi

{
  printf 'ended_at=%q\n' "$(date --iso-8601=seconds)"
  printf 'exit_status=%q\n' "$codex_status"
  printf 'tee_exit_status=%q\n' "$tee_status"
} >> "${session_dir}/session.meta"

((tee_status == 0)) || die "tee failed while writing events.jsonl"
exit "$codex_status"
