#!/usr/bin/env bash

set -euo pipefail

#-----------------------------------------------------------------------------
# jobindex-secret
#
# Store and retrieve encrypted credentials for Jobindex.
#
# Secrets are stored as GPG symmetric encrypted files:
#   ~/.secrets/jobindex/username.gpg
#   ~/.secrets/jobindex/password.gpg
#
# The script never stores plaintext credentials in shell startup files.
#
# USAGE
#   jobindex-secret init
#   jobindex-secret status
#   jobindex-secret set username
#   jobindex-secret set password
#   jobindex-secret get username
#   jobindex-secret get password
#   jobindex-secret delete username
#   jobindex-secret delete password
#   jobindex-secret --help
#   jobindex-secret -h
#
# EXAMPLES
#   jobindex-secret init
#   jobindex-secret set username
#   jobindex-secret set password
#   jobindex-secret get username
#   jobindex-secret status
#
# NOTES
#   - GPG symmetric encryption is used.
#   - GPG / pinentry will prompt for the encryption passphrase when needed.
#   - Retrieved secrets are printed to stdout. Therefore:
#       * do not run 'get' casually in a shared terminal,
#       * do not pipe it into logs,
#       * prefer having the Python script call it directly.
#-----------------------------------------------------------------------------

readonly SECRET_ROOT="${HOME}/.secrets/jobindex"
readonly USERNAME_FILE="${SECRET_ROOT}/username.gpg"
readonly PASSWORD_FILE="${SECRET_ROOT}/password.gpg"

function help_text() {
  cat <<'EOF'
jobindex-secret

Store and retrieve encrypted credentials for Jobindex.

USAGE
  jobindex-secret init
  jobindex-secret status
  jobindex-secret set username
  jobindex-secret set password
  jobindex-secret get username
  jobindex-secret get password
  jobindex-secret delete username
  jobindex-secret delete password
  jobindex-secret --help
  jobindex-secret -h

COMMANDS
  init
      Create the secret directory with restrictive permissions.

  status
      Show whether encrypted username/password files exist.

  set username
      Prompt for and store the username as an encrypted GPG file.

  set password
      Prompt for and store the password as an encrypted GPG file.

  get username
      Decrypt and print the username to stdout.

  get password
      Decrypt and print the password to stdout.

  delete username
      Delete the encrypted username file.

  delete password
      Delete the encrypted password file.

EXAMPLES
  jobindex-secret init
  jobindex-secret set username
  jobindex-secret set password
  jobindex-secret status
  jobindex-secret get username

SECURITY
  The decrypted secret is printed to stdout for the 'get' command. That is
  convenient for programmatic retrieval, but should not be used casually in
  interactive shells.

  The intended use is that a Python program calls this helper via subprocess
  and captures stdout directly in memory.

DEPENDENCIES
  - gpg
EOF
}

function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function require_command() {
  local cmd="$1"

  command -v "${cmd}" >/dev/null 2>&1 \
    || die "Required command not found: ${cmd}"
}

function init_store() {
  mkdir -p "${SECRET_ROOT}"
  chmod 700 "${HOME}/.secrets" 2>/dev/null || true
  chmod 700 "${SECRET_ROOT}"
}

function secret_file_for() {
  local field="${1:-}"

  case "${field}" in
    username)
      printf '%s\n' "${USERNAME_FILE}"
      ;;
    password)
      printf '%s\n' "${PASSWORD_FILE}"
      ;;
    *)
      die "Invalid field: ${field}. Use 'username' or 'password'."
      ;;
  esac
}

function prompt_secret() {
  local field="${1:-}"
  local value=''

  case "${field}" in
    username)
      read -r -p 'Enter Jobindex username: ' value
      ;;
    password)
      read -r -s -p 'Enter Jobindex password: ' value
      printf '\n' >&2
      ;;
    *)
      die "Invalid field: ${field}"
      ;;
  esac

  [[ -n "${value}" ]] || die "Empty ${field} not allowed."

  printf '%s' "${value}"
}

function set_secret() {
  local field="${1:-}"
  local file=''

  init_store
  file="$(secret_file_for "${field}")"

  umask 077

  prompt_secret "${field}" \
    | gpg \
        --symmetric \
        --cipher-algo AES256 \
        --output "${file}"

  chmod 600 "${file}"

  printf 'Stored encrypted %s at: %s\n' "${field}" "${file}" >&2
}

function get_secret() {
  local field="${1:-}"
  local file=''

  file="$(secret_file_for "${field}")"

  [[ -f "${file}" ]] || die "Encrypted ${field} file does not exist: ${file}"

  gpg --quiet --decrypt "${file}"
}

function delete_secret() {
  local field="${1:-}"
  local file=''

  file="$(secret_file_for "${field}")"

  if [[ -f "${file}" ]]; then
    rm -f -- "${file}"
    printf 'Deleted encrypted %s: %s\n' "${field}" "${file}"
  else
    printf 'No encrypted %s file found: %s\n' "${field}" "${file}"
  fi
}

function status_store() {
  init_store

  printf 'Secret directory: %s\n' "${SECRET_ROOT}"

  if [[ -f "${USERNAME_FILE}" ]]; then
    printf 'username: present\n'
  else
    printf 'username: missing\n'
  fi

  if [[ -f "${PASSWORD_FILE}" ]]; then
    printf 'password: present\n'
  else
    printf 'password: missing\n'
  fi
}

function main() {
  require_command gpg

  local cmd="${1:-}"
  local field="${2:-}"

  case "${cmd}" in
    init)
      init_store
      printf 'Initialized secret store: %s\n' "${SECRET_ROOT}"
      ;;
    status)
      status_store
      ;;
    set)
      [[ -n "${field}" ]] || die "Missing field for 'set'."
      set_secret "${field}"
      ;;
    get)
      [[ -n "${field}" ]] || die "Missing field for 'get'."
      get_secret "${field}"
      ;;
    delete)
      [[ -n "${field}" ]] || die "Missing field for 'delete'."
      delete_secret "${field}"
      ;;
    --help|-h|'')
      help_text
      ;;
    *)
      die "Unknown command: ${cmd}"
      ;;
  esac
}

main "$@"
