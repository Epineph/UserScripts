#!/bin/bash
################################################################################
# clone: A script to clone repositories via SSH or HTTPS
#
# Usage:
#   clone -r <repo> -p <protocol> -t <target_directory>
#   clone <repo> <protocol> <target_directory>
#
# If both options and positional arguments are mixed, options take precedence.
# Defaults:
#   - protocol: ssh
#   - target_directory: $HOME/repos
################################################################################

# Default values
protocol="ssh"
target_dir="$HOME/repos"
repo=""

# Function: Display Help
show_help() {
  cat << EOF
Usage: clone [options] | [positional arguments]

This script simplifies cloning Git repositories, supporting both SSH and HTTPS.
When no options are specified, the script interprets positional arguments.

Options:
  -r, --repo         [MANDATORY] Repository to clone (e.g., username/repository or full URL)
  -p, --protocol     [OPTIONAL]  Protocol to use: 'ssh' (default) or 'https'
  -t, --target       [OPTIONAL]  Target directory for cloning (default: \$HOME/repos)

Examples:
  1. Clone using options:
     clone -r openssl/openssl -p https -t /custom/dir
     clone -r https://github.com/openssl/openssl.git

  2. Clone using positional arguments:
     clone username/repository
     clone username/repository https /custom/dir

  3. Clone a repository with full URL:
     clone https://github.com/username/repository.git

Notes:
- If both options and positional arguments are provided, options take precedence.
- For simple usage, just pass 'username/repository'; it defaults to SSH.
EOF
}

# Parse command-line options
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--repo)
      repo="$2"
      shift 2
      ;;
    -p|--protocol)
      protocol="$2"
      shift 2
      ;;
    -t|--target)
      target_dir="$2"
      shift 2
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    -*)
      echo "Unknown option: $1"
      show_help
      exit 1
      ;;
    *)
      # Positional arguments are processed only if no options were provided
      if [[ -z "$repo" ]]; then
        repo="$1"
      elif [[ "$protocol" == "ssh" ]]; then
        protocol="$1"
      elif [[ "$target_dir" == "$HOME/repos" ]]; then
        target_dir="$1"
      else
        echo "Too many positional arguments or unknown input: $1"
        show_help
        exit 1
      fi
      shift
      ;;
  esac
done

# Validate inputs
if [[ -z "$repo" ]]; then
  echo "Error: Repository (-r or --repo) is required."
  show_help
  exit 1
fi

if [[ "$protocol" != "ssh" && "$protocol" != "https" ]]; then
  echo "Error: Protocol (-p or --protocol) must be 'ssh' or 'https'."
  show_help
  exit 1
fi

# Construct the URL based on the protocol
if [[ "$repo" =~ ^https?:// ]]; then
  # Repo is already a full URL
  git_url="$repo"
elif [[ "$repo" =~ ^[^/]+/[^/]+$ ]]; then
  # Repo is in username/repo format
  if [[ "$protocol" == "ssh" ]]; then
    git_url="git@github.com:${repo}.git"
  elif [[ "$protocol" == "https" ]]; then
    git_url="https://github.com/${repo}.git"
  fi
else
  echo "Error: Invalid repository format. Use username/repository or a full URL."
  show_help
  exit 1
fi

# Clone the repository
echo "Cloning $git_url into $target_dir..."
mkdir -p "$target_dir"
git -C "$target_dir" clone "$git_url" --recurse-submodules

if [[ $? -eq 0 ]]; then
  echo "Clone successful."
else
  echo "Clone failed."
  exit 1
fi

