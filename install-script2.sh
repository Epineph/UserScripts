#!/usr/bin/env bash

# install-script
# -----------------------------------------------------------------------------
# Install an executable script as a command.
#
# Default routing:
#   *.zsh       -> $HOME/.local/zsh-scripts/bin
#   everything  -> /usr/local/bin
#
# The final filename loses its last extension unless --preserve-extension is
# supplied. Explicit output directories are never added to PATH automatically.
# -----------------------------------------------------------------------------

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
readonly DEFAULT_MODE="755"
readonly ZSH_BIN_DIR="$HOME/.local/zsh-scripts/bin"

target=""
output_dir=""
install_mode="$DEFAULT_MODE"
preserve_extension=0
allow_no_shebang=0
verbose=0
target_explicit=0
output_explicit=0

declare -a positionals=()

function usage()
{
  cat <<'EOF'
Usage:
  install-script [OPTIONS] TARGET [OUTPUT_DIR]
  install-script [OPTIONS] --target TARGET [--output OUTPUT_DIR]

Install a script as an executable command. By default, the last filename
extension is removed from the installed command name.

Default destinations:
  *.zsh       $HOME/.local/zsh-scripts/bin
  all others  /usr/local/bin

When the default Zsh directory is not already in PATH, an idempotent managed
block is added to ~/.zshenv. An explicitly selected output directory is never
added to PATH automatically.

Options:
  -t, --target FILE
      Script to install. Alternatively, use the first positional argument.

  -o, --output DIR
      Destination directory. Alternatively, use the second positional
      argument.

  --preserve-extension
      Preserve the source filename extension.

  --install-perm MODE
  --install-permission MODE
      Installation mode in octal. Default: 755.

  --allow-no-shebang
      Permit a source file without a #! interpreter line. Such a file usually
      cannot be executed directly as a command.

  -v, --verbose
      Report source, destination, permission, PATH handling, and whether an
      existing destination was replaced.

  -h, --help
      Show this help text.

Examples:
  install-script ./cancel-vcpkg-timers.zsh
  install-script ./backup.sh /usr/local/bin
  install-script -t ./report.py -o "$HOME/.local/bin"
  install-script ./tool.zsh --preserve-extension
  install-script ./private-tool.sh --install-perm 700 --verbose
EOF
}

function die()
{
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function warn()
{
  printf 'Warning: %s\n' "$*" >&2
}

function print_verbose()
{
  (( verbose )) && printf '%s\n' "$*"
  return 0
}

function require_option_argument()
{
  local option="$1"
  local count="$2"

  (( count >= 2 )) || die "Missing argument after $option."
}

while (( $# > 0 )); do
  case "$1" in
    -t|--target)
      require_option_argument "$1" "$#"
      (( target_explicit == 0 )) || die 'Target was specified more than once.'
      target="$2"
      target_explicit=1
      shift 2
      ;;
    --target=*)
      (( target_explicit == 0 )) || die 'Target was specified more than once.'
      target="${1#*=}"
      [[ -n "$target" ]] || die 'The --target value cannot be empty.'
      target_explicit=1
      shift
      ;;
    -o|--output)
      require_option_argument "$1" "$#"
      (( output_explicit == 0 )) || die 'Output was specified more than once.'
      output_dir="$2"
      output_explicit=1
      shift 2
      ;;
    --output=*)
      (( output_explicit == 0 )) || die 'Output was specified more than once.'
      output_dir="${1#*=}"
      [[ -n "$output_dir" ]] || die 'The --output value cannot be empty.'
      output_explicit=1
      shift
      ;;
    --preserve-extension)
      preserve_extension=1
      shift
      ;;
    --install-perm|--install-permission)
      require_option_argument "$1" "$#"
      install_mode="$2"
      shift 2
      ;;
    --install-perm=*|--install-permission=*)
      install_mode="${1#*=}"
      [[ -n "$install_mode" ]] || die 'The permission mode cannot be empty.'
      shift
      ;;
    --allow-no-shebang)
      allow_no_shebang=1
      shift
      ;;
    -v|--verbose)
      verbose=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      positionals+=("$@")
      break
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      positionals+=("$1")
      shift
      ;;
  esac
done

if (( target_explicit )); then
  if (( ${#positionals[@]} > 0 )); then
    (( output_explicit == 0 && ${#positionals[@]} == 1 )) ||
      die 'Too many positional arguments.'
    output_dir="${positionals[0]}"
    output_explicit=1
  fi
else
  (( ${#positionals[@]} >= 1 )) || {
    usage >&2
    exit 2
  }

  target="${positionals[0]}"

  if (( ${#positionals[@]} >= 2 )); then
    (( output_explicit == 0 )) ||
      die 'Output was specified both positionally and with --output.'
    output_dir="${positionals[1]}"
    output_explicit=1
  fi

  (( ${#positionals[@]} <= 2 )) || die 'Too many positional arguments.'
fi

[[ "$install_mode" =~ ^[0-7]{3,4}$ ]] ||
  die "Invalid octal permission mode: $install_mode"

for command_name in install realpath stat; do
  command -v "$command_name" >/dev/null 2>&1 ||
    die "Required command not found: $command_name"
done

[[ -f "$target" ]] || die "Target is not a regular file: $target"
[[ -r "$target" ]] || die "Target is not readable: $target"

target="$(realpath -e -- "$target")"
source_name="$(basename -- "$target")"
source_name_lower="${source_name,,}"

if (( allow_no_shebang == 0 )); then
  IFS= read -r first_line < "$target" || first_line=""
  [[ "$first_line" == '#!'* ]] || {
    die 'Target has no #! interpreter line; use --allow-no-shebang to override.'
  }
fi

if (( preserve_extension )); then
  installed_name="$source_name"
else
  installed_name="${source_name%.*}"
  [[ -n "$installed_name" && "$installed_name" != "$source_name" ]] ||
    installed_name="$source_name"
fi

if [[ -z "$output_dir" ]]; then
  if [[ "$source_name_lower" == *.zsh ]]; then
    output_dir="$ZSH_BIN_DIR"
  else
    output_dir="/usr/local/bin"
  fi
fi

output_dir="$(realpath -m -- "$output_dir")"
destination="$output_dir/$installed_name"

[[ "$target" != "$destination" ]] ||
  die 'Source and destination resolve to the same path.'
[[ ! -d "$destination" ]] ||
  die "Destination is an existing directory: $destination"

function nearest_existing_parent()
{
  local path="$1"

  while [[ ! -e "$path" ]]; do
    [[ "$path" != / ]] || break
    path="$(dirname -- "$path")"
  done

  printf '%s\n' "$path"
}

function destination_needs_sudo()
{
  local directory="$1"
  local file="$2"
  local parent

  (( EUID != 0 )) || return 1

  if [[ -d "$directory" ]]; then
    [[ -w "$directory" && -x "$directory" ]] || return 0
  else
    parent="$(nearest_existing_parent "$directory")"
    [[ -d "$parent" && -w "$parent" && -x "$parent" ]] || return 0
  fi

  if [[ -e "$file" && ! -w "$file" ]]; then
    return 0
  fi

  return 1
}

created_output=0
replaced_output=0

[[ -e "$destination" ]] && replaced_output=1

if [[ ! -d "$output_dir" ]]; then
  if destination_needs_sudo "$output_dir" "$destination"; then
    sudo install -d -m 755 -- "$output_dir"
  else
    install -d -m 755 -- "$output_dir"
  fi

  created_output=1
  printf 'Created output directory: %s\n' "$output_dir"
fi

if destination_needs_sudo "$output_dir" "$destination"; then
  sudo install -D -m "$install_mode" -- "$target" "$destination"
else
  install -D -m "$install_mode" -- "$target" "$destination"
fi

function path_contains()
{
  local requested="$1"
  local requested_real entry entry_real
  local -a path_entries

  requested_real="$(realpath -m -- "$requested")"
  IFS=':' read -r -a path_entries <<< "${PATH:-}"

  for entry in "${path_entries[@]}"; do
    [[ -n "$entry" ]] || entry='.'
    entry_real="$(realpath -m -- "$entry")"
    [[ "$entry_real" == "$requested_real" ]] && return 0
  done

  return 1
}

function persist_zsh_bin_path()
{
  local zdotdir="${ZDOTDIR:-$HOME}"
  local zshenv="$zdotdir/.zshenv"
  local start_marker='# >>> install-script: zsh command PATH >>>'
  local end_marker='# <<< install-script: zsh command PATH <<<'
  local candidate backup
  local start_found=0
  local end_found=0

  command -v zsh >/dev/null 2>&1 ||
    die 'Zsh is required to validate the persistent PATH configuration.'

  if [[ -L "$zshenv" ]]; then
    zshenv="$(realpath -e -- "$zshenv")"
    zdotdir="$(dirname -- "$zshenv")"
  fi

  mkdir -p -- "$zdotdir"

  if [[ -f "$zshenv" ]]; then
    grep -Fqx -- "$start_marker" "$zshenv" && start_found=1
    grep -Fqx -- "$end_marker" "$zshenv" && end_found=1
  fi

  (( start_found == end_found )) || {
    die "Incomplete install-script PATH block in $zshenv"
  }

  (( start_found == 0 )) || return 0

  candidate="$(mktemp --tmpdir="$zdotdir" '.zshenv.install-script.XXXXXXXX')"

  if [[ -f "$zshenv" ]]; then
    cp -p -- "$zshenv" "$candidate"
  else
    chmod 644 -- "$candidate"
  fi

  {
    printf '\n%s\n' "$start_marker"
    printf '%s\n' 'typeset -U path PATH'
    printf '%s\n' 'path=("$HOME/.local/zsh-scripts/bin" $path)'
    printf '%s\n' 'export PATH'
    printf '%s\n' "$end_marker"
  } >> "$candidate"

  if ! zsh -f -n "$candidate"; then
    rm -f -- "$candidate"
    die "Generated invalid Zsh configuration; $zshenv was not changed."
  fi

  if [[ -f "$zshenv" ]]; then
    backup="$zshenv.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p -- "$zshenv" "$backup"
    print_verbose "Zsh configuration backup: $backup"
  fi

  mv -- "$candidate" "$zshenv"
  print_verbose "Added persistent PATH entry to: $zshenv"
}

path_status='already present'

if ! path_contains "$output_dir"; then
  if (( output_explicit == 0 )) && [[ "$source_name_lower" == *.zsh ]]; then
    persist_zsh_bin_path
    path_status='added persistently; available in the next Zsh process'
  else
    path_status='not present'
    warn "$output_dir is not in PATH; invoke the command as $destination"
  fi
fi

if (( verbose )); then
  actual_mode="$(stat -c '%a' -- "$destination")"
  symbolic_mode="$(stat -c '%A' -- "$destination")"
  symbolic_mode="${symbolic_mode:1}"

  printf 'Installed script:\n'
  printf '  Source:      %s\n' "$target"
  printf '  Destination: %s\n' "$destination"
  printf '  Permission:  %s (%s)\n' "$actual_mode" "$symbolic_mode"
  printf '  PATH:        %s\n' "$path_status"
  printf '  Directory:   %s\n' \
    "$([[ $created_output == 1 ]] && printf created || printf existing)"
  printf '  Existing:    %s\n' \
    "$([[ $replaced_output == 1 ]] && printf replaced || printf no)"
fi
