#!/usr/bin/env bash
###############################################################################
# Script: manage_conda_env.sh
# Description:
#   A standalone script for managing Conda/Micromamba environments.
#   Handles:
#     - Environment creation/activation   (-e / --env / --environment)
#     - Python version                    (-p / --python / --python-version / --py-version)
#     - Channels                           (-c / --channel)
#     - Package installation               (-i / --install)
#     - Immediate activation option        (-u / --use / --use-now)
#
# Usage: manage_conda_env.sh [options] [env_name]
#
# Examples:
#   ./manage_conda_env.sh
#   ./manage_conda_env.sh -e myEnv
#   ./manage_conda_env.sh --env=myEnv --python 3.12.4 --channel conda-forge,bioconda -u
#   ./manage_conda_env.sh -i numpy scipy matplotlib
#   ./manage_conda_env.sh -e=myEnv --install numpy pandas -u
###############################################################################

# -------------------------------
# 0. Usage / Help Function
# -------------------------------
usage() {
  if command -v bat &>/dev/null; then
    bat --style="grid,header" --paging="never" --color="always" --language="bash" <<'EOF'
###############################################################################
Usage: manage_conda_env.sh [OPTIONS] [ENV_NAME]

Description:
  Manage Conda/Micromamba environments: create, activate, and install packages.

Options:
  -e, --env, --environment <NAME>  Specify environment name.
  -p, --python, --python-version, --py-version <VERSION>
                                   Specify Python version (e.g., 3.12.4).
  -c, --channel <CHANNELS>         Provide channels, space- or comma-separated.
  -i, --install <PACKAGES>         Install packages into the environment.
  -u, --use, --use-now             Activate environment after creation.
  -h, --help                       Show this help message.

Examples:
  ./manage_conda_env.sh
  ./manage_conda_env.sh -e myEnv
  ./manage_conda_env.sh --env=myEnv --python 3.12.4 --channel conda-forge,bioconda -u
  ./manage_conda_env.sh -i numpy scipy matplotlib
  ./manage_conda_env.sh -e=myEnv --install numpy pandas -u
###############################################################################
EOF
  else
    cat <<'EOF'
###############################################################################
Usage: manage_conda_env.sh [OPTIONS] [ENV_NAME]

Description:
  Manage Conda/Micromamba environments: create, activate, and install packages.

Options:
  -e, --env, --environment <NAME>  Specify environment name.
  -p, --python, --python-version, --py-version <VERSION>
                                   Specify Python version (e.g., 3.12.4).
  -c, --channel <CHANNELS>         Provide channels, space- or comma-separated.
  -i, --install <PACKAGES>         Install packages into the environment.
  -u, --use, --use-now             Activate environment after creation.
  -h, --help                       Show this help message.

Examples:
  ./manage_conda_env.sh
  ./manage_conda_env.sh -e myEnv
  ./manage_conda_env.sh --env=myEnv --python 3.12.4 --channel conda-forge,bioconda -u
  ./manage_conda_env.sh -i numpy scipy matplotlib
  ./manage_conda_env.sh -e=myEnv --install numpy pandas -u
###############################################################################
EOF
  fi
}

# If the user passes -h/--help, show usage and exit.
for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    usage
    exit 0
  fi
done

# --------------------------------
# 1. If NO arguments -> prompt
# --------------------------------
if [[ $# -eq 0 ]]; then
  echo "No arguments specified."
  read -n 1 -r -p "Show help? [Y/n] " ans
  echo
  ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
  if [[ "$ans" == "y" || -z "$ans" ]]; then
    usage
  fi
  exit 1
fi

# --------------------------------
# 2. Initialize variables
# --------------------------------
env_name=""
python_version=""
channels=""
use_now="0"
install_packages=""

# --------------------------------
# 3. Parse Arguments
# --------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e=*|--env=*|--environment=*)
      env_name="${1#*=}"
      shift
      ;;
    -e|--env|--environment)
      env_name="$2"
      shift 2
      ;;
    -p=*|--python=*|--python-version=*|--py-version=*)
      python_version="${1#*=}"
      shift
      ;;
    -p|--python|--python-version|--py-version)
      python_version="$2"
      shift 2
      ;;
    -c=*|--channel=*)
      channels="${1#*=}"
      shift
      ;;
    -c|--channel)
      channels="$2"
      shift 2
      ;;
    -u|--use|--use-now)
      use_now="1"
      shift
      ;;
    -i=*|--install=*)
      install_packages="${1#*=}"
      shift
      ;;
    -i|--install)
      shift
      while [[ -n "$1" && "$1" != -* ]]; do
        install_packages+="$1 "
        shift
      done
      ;;
    *)
      if [[ -z "$env_name" ]]; then
        env_name="$1"
      fi
      shift
      ;;
  esac
done

current_env="${CONDA_DEFAULT_ENV:-}"

# -----------------------------------------------------------
# 4. If installing packages but no environment is active
# -----------------------------------------------------------
if [[ -n "$install_packages" && -z "$env_name" ]]; then
  if [[ -n "$current_env" && "$current_env" != "base" ]]; then
    echo "Installing packages into current environment: $current_env"
    conda install -n "$current_env" -y $install_packages
  else
    echo "Error: No active environment to install packages into."
    read -n 1 -r -p "Show help? [Y/n] " ans
    echo
    ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
    if [[ "$ans" == "y" || -z "$ans" ]]; then
      usage
    fi
    exit 1
  fi
  exit 0
fi

# -------------------------------------------------------------
# 5. If no environment is specified
# -------------------------------------------------------------
if [[ -z "$env_name" ]]; then
  if [[ -z "$current_env" || "$current_env" == "base" ]]; then
    echo "No environment specified. Activating base..."
    conda activate base
  else
    echo "No environment specified. Staying in: $current_env"
  fi
  exit 0
fi

# -------------------------------------------------------------
# 6. Check if environment exists; create if not
# -------------------------------------------------------------
if ! conda env list | awk '{print $1}' | grep -qx "$env_name"; then
  echo "Creating environment: $env_name"
  conda create -y -n "$env_name" python="$python_version" -c ${channels//,/ }
fi

# -------------------------------------------------------------
# 7. Activate and install packages (if requested)
# -------------------------------------------------------------
if [[ "$use_now" == "1" ]]; then
  conda activate "$env_name"
fi

if [[ -n "$install_packages" ]]; then
  conda install -n "$env_name" -y $install_packages
fi

exit 0

