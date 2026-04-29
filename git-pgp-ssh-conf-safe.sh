from pathlib import Path

script = r'''#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# -----------------------------------------------------------------------------
# git-pgp-ssh-conf-safe.sh
#
# Configure Git identity, GPG commit signing, and SSH authentication keys without
# printing sensitive values to stdout. Values may be read from:
#
#   1. An ordinary KEY=VALUE secrets file.
#   2. A GPG-encrypted KEY=VALUE secrets file.
#   3. Hidden terminal prompts.
#
# Public keys are written to files by default. They are only printed when
# --show-public-keys is explicitly supplied.
# -----------------------------------------------------------------------------

readonly PROG="${0##*/}"

SECRETS_FILE=""
SECRETS_GPG=""
OUTPUT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/git-ssh-gpg-bootstrap"
REDACT=1
SHOW_PUBLIC_KEYS=0
COPY_PUBLIC_KEYS=0
SKIP_GPG=0
SKIP_SSH=0
ADD_TO_AGENT=0
BACKUP_EXISTING=0
OVERWRITE_EXISTING=0
DRY_RUN=0

declare -A SECRET=()

# -----------------------------------------------------------------------------
# Messaging
# -----------------------------------------------------------------------------

function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function info() {
  printf '%s\n' "$*" >&2
}

function ok() {
  printf 'OK: %s\n' "$*" >&2
}

function run_cmd() {
  if (( DRY_RUN )); then
    printf '[dry-run] ' >&2
    printf '%q ' "$@" >&2
    printf '\n' >&2
    return 0
  fi

  "$@"
}

function need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

function bool_yes() {
  case "${1,,}" in
    1|y|yes|true|on) return 0 ;;
    *) return 1 ;;
  esac
}

function lower() {
  printf '%s' "${1,,}"
}

function expand_path() {
  local path="$1"

  case "$path" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${path#~/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

function show_help() {
  cat <<EOF
Usage:
  $PROG [options]

Purpose:
  Configure Git identity, GPG commit signing, and an SSH key for GitHub without
  exposing credentials during screen recording.

Core options:
  --secrets-file PATH       Read KEY=VALUE secrets from a plaintext file.
  --secrets-gpg PATH        Decrypt a GPG-encrypted KEY=VALUE secrets file.
  --output-dir PATH         Directory for exported public keys.
                            Default: $OUTPUT_DIR
  --show-public-keys        Print public keys to stdout. Default: disabled.
  --copy-public-keys        Copy public keys to clipboard if wl-copy, xclip,
                            xsel, or pbcopy is available.
  --no-redact               Allow more descriptive terminal messages.
  --dry-run                 Show intended actions without changing files.
  --skip-gpg                Do not configure or generate a GPG key.
  --skip-ssh                Do not configure or generate an SSH key.
  --add-to-agent            Run ssh-add for the generated SSH private key.
  --backup-existing         Backup an existing SSH key path before replacing.
  --overwrite-existing      Replace an existing SSH key path without backup.
  -h, --help                Show this help text.

Supported secrets keys:
  GIT_USERNAME              Git user.name.
  GIT_EMAIL                 Git user.email.
  SIGN_ALL_COMMITS          yes/no; set commit.gpgsign globally.

  GPG_KEY_ID                Existing GPG fingerprint/key ID. If set, the script
                            configures Git to use it instead of generating one.
  GPG_NAME                  Real name for generated GPG key.
  GPG_EMAIL                 Email for generated GPG key.
  GPG_PASSPHRASE            Passphrase for generated GPG key.
  GPG_EXPIRE                Expiry, e.g. 2y, 1y, 6m, 0. Default: 2y.

  SSH_EMAIL                 Email/comment for SSH key.
  SSH_KEY_PATH              Default: ~/.ssh/id_ed25519_github.
  SSH_KEY_TYPE              Default: ed25519.
  SSH_KEY_BITS              Used for RSA only. Default: 4096.
  SSH_KEY_COMMENT           Comment for SSH key. Default: SSH_EMAIL.
  SSH_PASSPHRASE            Passphrase for SSH key.
  BACKUP_EXISTING           yes/no; same as --backup-existing.
  OVERWRITE_EXISTING        yes/no; same as --overwrite-existing.
  ADD_TO_AGENT              yes/no; same as --add-to-agent.

Plaintext secrets file example:
  GIT_USERNAME='Your Name'
  GIT_EMAIL='you@example.com'
  SIGN_ALL_COMMITS='yes'
  GPG_NAME='Your Name'
  GPG_EMAIL='you@example.com'
  GPG_PASSPHRASE='long-gpg-passphrase'
  SSH_EMAIL='you@example.com'
  SSH_KEY_PATH='~/.ssh/id_ed25519_github'
  SSH_PASSPHRASE='long-ssh-passphrase'

Encrypt that file:
  gpg --symmetric --cipher-algo AES256 \\
    --output git-ssh-gpg.secrets.env.gpg \\
    git-ssh-gpg.secrets.env

Run without exposing values:
  $PROG --secrets-gpg git-ssh-gpg.secrets.env.gpg --copy-public-keys

Notes:
  - Public keys are not secret, but they may still reveal your email/comment.
  - Private keys and passphrases are never printed by this script.
  - Avoid homemade ciphers. Use GPG/age/sops/openssl for real secrecy.
EOF
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

function parse_args() {
  while (($#)); do
    case "$1" in
      --secrets-file)
        [[ $# -ge 2 ]] || die "--secrets-file requires PATH."
        SECRETS_FILE="$2"
        shift 2
        ;;
      --secrets-gpg)
        [[ $# -ge 2 ]] || die "--secrets-gpg requires PATH."
        SECRETS_GPG="$2"
        shift 2
        ;;
      --output-dir)
        [[ $# -ge 2 ]] || die "--output-dir requires PATH."
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --show-public-keys)
        SHOW_PUBLIC_KEYS=1
        shift
        ;;
      --copy-public-keys)
        COPY_PUBLIC_KEYS=1
        shift
        ;;
      --no-redact)
        REDACT=0
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --skip-gpg)
        SKIP_GPG=1
        shift
        ;;
      --skip-ssh)
        SKIP_SSH=1
        shift
        ;;
      --add-to-agent)
        ADD_TO_AGENT=1
        shift
        ;;
      --backup-existing)
        BACKUP_EXISTING=1
        shift
        ;;
      --overwrite-existing)
        OVERWRITE_EXISTING=1
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  [[ -z "$SECRETS_FILE" || -z "$SECRETS_GPG" ]] \
    || die "Use either --secrets-file or --secrets-gpg, not both."

  OUTPUT_DIR="$(expand_path "$OUTPUT_DIR")"
}

# -----------------------------------------------------------------------------
# Secrets parsing
# -----------------------------------------------------------------------------

function strip_outer_quotes() {
  local value="$1"

  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
    value="${value//\\\"/\"}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi

  printf '%s' "$value"
}

function trim() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  printf '%s' "$value"
}

function parse_env_file() {
  local path="$1"
  local line key value

  [[ -r "$path" ]] || die "Cannot read secrets file: $path"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"

    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue

    [[ "$line" == *=* ]] || die "Invalid secrets line: $line"

    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"

    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
      || die "Invalid variable name in secrets file: $key"

    SECRET["$key"]="$(strip_outer_quotes "$value")"
  done < "$path"
}

function check_plaintext_permissions() {
  local path="$1"
  local mode

  [[ -f "$path" ]] || die "Secrets file does not exist: $path"

  mode="$(stat -c '%a' "$path" 2>/dev/null || printf '')"
  if [[ -n "$mode" && "$mode" != "600" && "$mode" != "400" ]]; then
    die "Refusing plaintext secrets file unless mode is 600 or 400: $path"
  fi
}

function decrypt_gpg_to_temp() {
  local encrypted="$1"
  local runtime_dir tmp

  need_cmd gpg

  [[ -f "$encrypted" ]] || die "Encrypted secrets file not found: $encrypted"

  runtime_dir="${XDG_RUNTIME_DIR:-/tmp}"
  tmp="$(mktemp "$runtime_dir/git-ssh-gpg-secrets.XXXXXX")"
  chmod 600 "$tmp"

  if ! gpg --quiet --decrypt "$encrypted" > "$tmp"; then
    rm -f "$tmp"
    die "Could not decrypt secrets file: $encrypted"
  fi

  parse_env_file "$tmp"

  if command -v shred >/dev/null 2>&1; then
    shred -u "$tmp" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

function load_secrets() {
  if [[ -n "$SECRETS_FILE" ]]; then
    check_plaintext_permissions "$SECRETS_FILE"
    parse_env_file "$SECRETS_FILE"
  elif [[ -n "$SECRETS_GPG" ]]; then
    decrypt_gpg_to_temp "$SECRETS_GPG"
  fi

  if [[ -n "${SECRET[BACKUP_EXISTING]:-}" ]]; then
    bool_yes "${SECRET[BACKUP_EXISTING]}" && BACKUP_EXISTING=1
  fi

  if [[ -n "${SECRET[OVERWRITE_EXISTING]:-}" ]]; then
    bool_yes "${SECRET[OVERWRITE_EXISTING]}" && OVERWRITE_EXISTING=1
  fi

  if [[ -n "${SECRET[ADD_TO_AGENT]:-}" ]]; then
    bool_yes "${SECRET[ADD_TO_AGENT]}" && ADD_TO_AGENT=1
  fi
}

function get_secret() {
  local key="$1"
  local default="${2:-}"

  if [[ -n "${SECRET[$key]:-}" ]]; then
    printf '%s' "${SECRET[$key]}"
  elif [[ -n "${!key:-}" ]]; then
    printf '%s' "${!key}"
  else
    printf '%s' "$default"
  fi
}

function prompt_value() {
  local key="$1"
  local prompt="$2"
  local default="${3:-}"
  local secret="${4:-0}"
  local value

  value="$(get_secret "$key" "$default")"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi

  if (( secret || REDACT )); then
    read -r -s -p "$prompt (hidden): " value
    printf '\n' >&2
  else
    read -r -p "$prompt: " value
  fi

  printf '%s' "$value"
}

function require_nonempty() {
  local name="$1"
  local value="$2"

  [[ -n "$value" ]] || die "$name is required."
}

# -----------------------------------------------------------------------------
# Git configuration
# -----------------------------------------------------------------------------

function configure_git_identity() {
  local git_username git_email

  git_username="$(prompt_value GIT_USERNAME 'Git user.name')"
  git_email="$(prompt_value GIT_EMAIL 'Git user.email')"

  require_nonempty "GIT_USERNAME" "$git_username"
  require_nonempty "GIT_EMAIL" "$git_email"

  run_cmd git config --global user.name "$git_username"
  run_cmd git config --global user.email "$git_email"

  ok "Configured Git identity."
}

# -----------------------------------------------------------------------------
# GPG configuration
# -----------------------------------------------------------------------------

function latest_secret_fingerprint_for_email() {
  local email="$1"

  gpg --list-secret-keys --with-colons --fingerprint "$email" 2>/dev/null \
    | awk -F: '
        /^sec:/ { in_secret = 1 }
        /^fpr:/ && in_secret { fingerprint = $10; in_secret = 0 }
        END { print fingerprint }
      '
}

function write_gpg_batch_file() {
  local path="$1"
  local name="$2"
  local email="$3"
  local passphrase="$4"
  local expire="$5"

  cat > "$path" <<EOF
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: sign
Name-Real: $name
Name-Email: $email
Expire-Date: $expire
Passphrase: $passphrase
%commit
EOF

  chmod 600 "$path"
}

function generate_or_configure_gpg() {
  local git_username git_email gpg_name gpg_email gpg_passphrase
  local gpg_expire gpg_key_id batch_file runtime_dir public_out
  local sign_all

  (( SKIP_GPG )) && {
    info "Skipping GPG configuration."
    return 0
  }

  need_cmd gpg
  need_cmd git

  gpg_key_id="$(get_secret GPG_KEY_ID)"
  sign_all="$(lower "$(get_secret SIGN_ALL_COMMITS yes)")"

  if [[ -z "$gpg_key_id" ]]; then
    git_username="$(git config --global user.name || true)"
    git_email="$(git config --global user.email || true)"

    gpg_name="$(prompt_value GPG_NAME 'GPG real name' "$git_username")"
    gpg_email="$(prompt_value GPG_EMAIL 'GPG email' "$git_email")"
    gpg_passphrase="$(prompt_value GPG_PASSPHRASE 'GPG passphrase' '' 1)"
    gpg_expire="$(get_secret GPG_EXPIRE 2y)"

    require_nonempty "GPG_NAME" "$gpg_name"
    require_nonempty "GPG_EMAIL" "$gpg_email"
    require_nonempty "GPG_PASSPHRASE" "$gpg_passphrase"

    runtime_dir="${XDG_RUNTIME_DIR:-/tmp}"
    batch_file="$(mktemp "$runtime_dir/git-gpg-batch.XXXXXX")"

    write_gpg_batch_file \
      "$batch_file" "$gpg_name" "$gpg_email" "$gpg_passphrase" "$gpg_expire"

    if (( DRY_RUN )); then
      info "[dry-run] Would generate a new EdDSA GPG signing key."
    else
      gpg --batch --pinentry-mode loopback --generate-key "$batch_file" \
        >/dev/null
    fi

    if command -v shred >/dev/null 2>&1; then
      shred -u "$batch_file" 2>/dev/null || rm -f "$batch_file"
    else
      rm -f "$batch_file"
    fi

    if (( ! DRY_RUN )); then
      gpg_key_id="$(latest_secret_fingerprint_for_email "$gpg_email")"
    else
      gpg_key_id="DRY-RUN-GPG-FINGERPRINT"
    fi
  fi

  require_nonempty "GPG_KEY_ID" "$gpg_key_id"

  run_cmd git config --global user.signingkey "$gpg_key_id"

  if bool_yes "$sign_all"; then
    run_cmd git config --global commit.gpgsign true
  fi

  mkdir -p "$OUTPUT_DIR"
  public_out="$OUTPUT_DIR/github-gpg-public.asc"

  if (( DRY_RUN )); then
    info "[dry-run] Would export public GPG key to: $public_out"
  else
    gpg --armor --export "$gpg_key_id" > "$public_out"
    chmod 600 "$public_out"
  fi

  ok "Configured GPG signing."
  info "GPG public key file: $public_out"

  if (( SHOW_PUBLIC_KEYS && ! DRY_RUN )); then
    cat "$public_out"
  fi

  if (( COPY_PUBLIC_KEYS && ! DRY_RUN )); then
    copy_file_to_clipboard "$public_out"
  fi
}

# -----------------------------------------------------------------------------
# SSH configuration
# -----------------------------------------------------------------------------

function backup_path_pair() {
  local private_path="$1"
  local backup_dir="$HOME/.ssh_backup/$(date +%Y%m%d-%H%M%S)"

  mkdir -p "$backup_dir"

  if command -v rsync >/dev/null 2>&1; then
    [[ -e "$private_path" ]] && rsync -a "$private_path" "$backup_dir/"
    [[ -e "${private_path}.pub" ]] && rsync -a "${private_path}.pub" "$backup_dir/"
  else
    [[ -e "$private_path" ]] && cp -a "$private_path" "$backup_dir/"
    [[ -e "${private_path}.pub" ]] && cp -a "${private_path}.pub" "$backup_dir/"
  fi

  rm -f "$private_path" "${private_path}.pub"

  ok "Backed up existing SSH key pair."
  info "Backup directory: $backup_dir"
}

function ssh_keygen_args() {
  local type="$1"
  local bits="$2"
  local comment="$3"
  local path="$4"
  local passphrase="$5"

  case "$type" in
    ed25519)
      ssh-keygen -q -t ed25519 -a 100 -C "$comment" -f "$path" -N "$passphrase"
      ;;
    rsa)
      ssh-keygen -q -t rsa -b "$bits" -C "$comment" -f "$path" -N "$passphrase"
      ;;
    *)
      die "Unsupported SSH_KEY_TYPE: $type"
      ;;
  esac
}

function generate_ssh_key() {
  local ssh_email ssh_path ssh_type ssh_bits ssh_comment ssh_passphrase
  local public_out

  (( SKIP_SSH )) && {
    info "Skipping SSH configuration."
    return 0
  }

  need_cmd ssh-keygen

  ssh_email="$(prompt_value SSH_EMAIL 'SSH email/comment')"
  ssh_path="$(expand_path "$(get_secret SSH_KEY_PATH '~/.ssh/id_ed25519_github')")"
  ssh_type="$(lower "$(get_secret SSH_KEY_TYPE ed25519)")"
  ssh_bits="$(get_secret SSH_KEY_BITS 4096)"
  ssh_comment="$(get_secret SSH_KEY_COMMENT "$ssh_email")"
  ssh_passphrase="$(prompt_value SSH_PASSPHRASE 'SSH key passphrase' '' 1)"

  require_nonempty "SSH_EMAIL" "$ssh_email"
  require_nonempty "SSH_KEY_PATH" "$ssh_path"

  mkdir -p "$(dirname "$ssh_path")"
  chmod 700 "$(dirname "$ssh_path")"

  if [[ -e "$ssh_path" || -e "${ssh_path}.pub" ]]; then
    if (( BACKUP_EXISTING )); then
      backup_path_pair "$ssh_path"
    elif (( OVERWRITE_EXISTING )); then
      rm -f "$ssh_path" "${ssh_path}.pub"
    else
      die "SSH key exists. Use --backup-existing or --overwrite-existing."
    fi
  fi

  if (( DRY_RUN )); then
    info "[dry-run] Would generate SSH key: $ssh_path"
  else
    ssh_keygen_args \
      "$ssh_type" "$ssh_bits" "$ssh_comment" "$ssh_path" "$ssh_passphrase"
    chmod 600 "$ssh_path"
    chmod 644 "${ssh_path}.pub"
  fi

  ok "Generated SSH key."
  info "SSH public key file: ${ssh_path}.pub"

  mkdir -p "$OUTPUT_DIR"
  public_out="$OUTPUT_DIR/github-ssh-public.pub"

  if (( DRY_RUN )); then
    info "[dry-run] Would copy SSH public key to: $public_out"
  else
    cp "${ssh_path}.pub" "$public_out"
    chmod 600 "$public_out"
  fi

  if (( ADD_TO_AGENT && ! DRY_RUN )); then
    add_ssh_key_to_agent "$ssh_path"
  fi

  if (( SHOW_PUBLIC_KEYS && ! DRY_RUN )); then
    cat "$public_out"
  fi

  if (( COPY_PUBLIC_KEYS && ! DRY_RUN )); then
    copy_file_to_clipboard "$public_out"
  fi
}

function add_ssh_key_to_agent() {
  local ssh_path="$1"

  need_cmd ssh-add

  if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
    eval "$(ssh-agent -s)" >/dev/null
  fi

  ssh-add "$ssh_path"
  ok "Added SSH key to ssh-agent."
}

# -----------------------------------------------------------------------------
# Clipboard
# -----------------------------------------------------------------------------

function copy_file_to_clipboard() {
  local file="$1"

  if command -v wl-copy >/dev/null 2>&1; then
    wl-copy < "$file"
  elif command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard < "$file"
  elif command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --input < "$file"
  elif command -v pbcopy >/dev/null 2>&1; then
    pbcopy < "$file"
  else
    info "Clipboard tool not found; install wl-clipboard, xclip, or xsel."
    return 1
  fi

  ok "Copied public key material to clipboard without printing it."
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

function main() {
  parse_args "$@"

  need_cmd git

  load_secrets

  mkdir -p "$OUTPUT_DIR"
  chmod 700 "$OUTPUT_DIR"

  configure_git_identity
  generate_or_configure_gpg
  generate_ssh_key

  ok "Finished."
  info "Public key exports are in: $OUTPUT_DIR"

  if (( ! SHOW_PUBLIC_KEYS )); then
    info "No public keys were printed. Use --show-public-keys only when safe."
  fi
}

main "$@"
'''

template = r'''# git-ssh-gpg.secrets.env
#
# Keep this file plaintext only briefly. Encrypt it and then remove the
# plaintext copy.
#
# Recommended permissions while plaintext:
#   chmod 600 git-ssh-gpg.secrets.env

GIT_USERNAME='Your Name'
GIT_EMAIL='you@example.com'
SIGN_ALL_COMMITS='yes'

GPG_NAME='Your Name'
GPG_EMAIL='you@example.com'
GPG_PASSPHRASE='replace-with-a-long-gpg-passphrase'
GPG_EXPIRE='2y'

SSH_EMAIL='you@example.com'
SSH_KEY_PATH='~/.ssh/id_ed25519_github'
SSH_KEY_TYPE='ed25519'
SSH_KEY_COMMENT='you@example.com'
SSH_PASSPHRASE='replace-with-a-long-ssh-passphrase'

BACKUP_EXISTING='yes'
ADD_TO_AGENT='no'
'''

out_dir = Path("/mnt/data")
script_path = out_dir / "git-pgp-ssh-conf-safe.sh"
template_path = out_dir / "git-ssh-gpg.secrets.env.template"

script_path.write_text(script)
template_path.write_text(template)
script_path.chmod(0o755)
template_path.chmod(0o600)

print(f"Wrote: {script_path}")
print(f"Wrote: {template_path}")
