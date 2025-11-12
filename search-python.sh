#!/usr/bin/env python3
"""
Search PyPI, rank matches, optionally install via conda or pip based on environment.

Usage Examples
--------------
# Default: detect micromamba/mamba/conda, require active venv or --virtual-env
./python-search-enumerated-install.py numpy pandas requests

# Specify virtual environment name (will activate via micromamba/mamba/conda run)
./python-search-enumerated-install.py --virtual-env myEnv scipy matplotlib

# Force pip-only installation even if conda is available
./python-search-enumerated-install.py --no-conda seaborn
"""
import argparse
import shutil
import subprocess
import sys
import os


def detect_conda_manager():
    """
    Detect available conda-style package manager in PATH.
    Preference order: micromamba, mamba, conda.
    Returns the command name or None if not found.
    """
    for cmd in ('micromamba', 'mamba', 'conda'):
        if shutil.which(cmd):
            return cmd
    return None


def ensure_virtual_env(venv_name):
    """
    Ensure a virtual environment is active or specified.
    If no venv active (sys.executable in /usr/bin) and no --virtual-env, exit.
    Returns the name of the env to use for conda run (may be None if pip-only).
    """
    # Check if user provided a venv name
    if venv_name:
        return venv_name

    # If VIRTUAL_ENV set, assume active
    if os.getenv('VIRTUAL_ENV'):
        return None

    # If sys.executable is system python, error
    if sys.executable.startswith('/usr/bin/'):
        sys.exit("ERROR: no virtual environment active; use --virtual-env <name> to specify one.")
    return None


def partition_packages(pkgs, conda_mgr, use_conda):
    """
    Split package list into those available via conda-forge and those pip-only.
    Checks conda-forge availability by calling `<mgr> search pkg --json` if supported.
    Returns (conda_pkgs, pip_pkgs).
    """
    conda_pkgs = []
    pip_pkgs = []

    for pkg in pkgs:
        if use_conda and conda_mgr:
            try:
                # try conda search
                cmd = [conda_mgr, 'search', pkg, '--channel', 'conda-forge', '--json']
                result = subprocess.run(cmd, capture_output=True, text=True)
                if result.returncode == 0 and result.stdout.strip().startswith('{'):
                    conda_pkgs.append(pkg)
                    continue
            except Exception:
                pass
        pip_pkgs.append(pkg)

    return conda_pkgs, pip_pkgs


def install_packages(conda_mgr, env, conda_pkgs, pip_pkgs):
    """
    Install conda_pkgs via conda_mgr and pip_pkgs via pip.
    If env is provided, runs installer within that env using `run` where supported.
    """
    # Install conda packages
    if conda_pkgs and conda_mgr:
        # Base install command
        base_cmd = [conda_mgr, 'install', '--channel-priority', 'flexible', '-c', 'conda-forge'] + conda_pkgs
        if env and conda_mgr == 'micromamba':
            cmd = [conda_mgr, 'run', '-n', env, '--'] + base_cmd
        elif env:
            cmd = [conda_mgr, 'run', '-n', env, '--'] + base_cmd
        else:
            cmd = base_cmd
        print(f"Installing via {conda_mgr}: {' '.join(cmd)}")
        subprocess.run(cmd, check=True)

    # Install pip packages
    if pip_pkgs:
        pip_cmd = [sys.executable, '-m', 'pip', 'install'] + pip_pkgs
        print(f"Installing via pip: {' '.join(pip_cmd)}")
        subprocess.run(pip_cmd, check=True)


def main():
    parser = argparse.ArgumentParser(
        description="Search & install PyPI packages, auto-choosing conda or pip.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="See usage examples in the module docstring."
    )
    parser.add_argument(
        '--no-conda', action='store_true',
        help='Force pip-only installation even if conda is available.'
    )
    parser.add_argument(
        '-v', '--virtual-env', metavar='ENV',
        help='Name of the conda/micromamba environment to (run|activate) before installing.'
    )
    parser.add_argument(
        'packages', nargs='+',
        help='List of package names to install.'
    )
    args = parser.parse_args()

    # Detect conda manager
    conda_mgr = detect_conda_manager()

    # Decide whether to use conda
    use_conda = conda_mgr is not None and not args.no_conda

    # Ensure venv context for pip or conda
    env = ensure_virtual_env(args.virtual_env)

    # Partition packages
    conda_pkgs, pip_pkgs = partition_packages(args.packages, conda_mgr, use_conda)

    if not conda_pkgs and not pip_pkgs:
        print("No packages to install.")
        return

    # Install
    install_packages(conda_mgr, env, conda_pkgs, pip_pkgs)


if __name__ == '__main__':
    main()
