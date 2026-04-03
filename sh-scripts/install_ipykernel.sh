#!/usr/bin/env bash
# =============================================================================
# install_ipykernel.sh
# =============================================================================
# A helper script to install and register an IPython kernel for Jupyter Notebook.
# 
# This script supports both pip- and conda-based installations.
# 
# Usage:
#   ./install_ipykernel.sh [-n KERNEL_NAME] [-u] [-c]
# 
# Options:
#   -n KERNEL_NAME  Specify the name for the new kernel (default: "python3").
#   -u              Install the kernel for the current user only (adds --user flag).
#   -c              Use conda to install ipykernel instead of pip.
#   -h              Display this help message and exit.
# 
# Examples:
#   # Install with pip and register as "myenv":
#   ./install_ipykernel.sh -n myenv
# 
#   # Install with pip for current user:
#   ./install_ipykernel.sh -u
# 
#   # Install using conda and register as "conda_env":
#   ./install_ipykernel.sh -c -n conda_env
# =============================================================================

# Default values
KERNEL_NAME="python3"
USER_FLAG=""
USE_CONDA=false

# Function to display help
usage() {
  sed -n '2,15p' "$0"
  exit 1
}

# Parse command-line options
while getopts ":n:uch" opt; do
  case ${opt} in
    n )
      KERNEL_NAME="$OPTARG"
      ;;
    u )
      USER_FLAG="--user"
      ;;
    c )
      USE_CONDA=true
      ;;
    h )
      usage
      ;;
    \? )
      echo "Error: Invalid option -$OPTARG" >&2
      usage
      ;;
    : )
      echo "Error: Option -$OPTARG requires an argument." >&2
      usage
      ;;
  esac
done

# Main installation logic
if [ "$USE_CONDA" = true ]; then
  echo "Installing ipykernel via conda..."
  # If this fails, user needs to ensure conda environment is active
  conda install ipykernel -y || { echo "Conda installation failed." >&2; exit 1; }
else
  echo "Installing ipykernel via pip..."
  python -m pip install ipykernel ${USER_FLAG} || { echo "pip installation failed." >&2; exit 1; }
fi

# Register the kernel
echo "Registering IPython kernel as '$KERNEL_NAME'..."
python -m ipykernel install ${USER_FLAG} --name "$KERNEL_NAME" --display-name "Python ($KERNEL_NAME)" \
  || { echo "Kernel registration failed." >&2; exit 1; }

echo "Success! Kernel '$KERNEL_NAME' is now available in Jupyter Notebook."

