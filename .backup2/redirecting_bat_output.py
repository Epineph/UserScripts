#!/usr/bin/env python3
import os
import subprocess
import sys
from prompt_toolkit import prompt
from prompt_toolkit.completion import PathCompleter, WordCompleter

def run_command(command):
    """Run a shell command and return its output."""
    try:
        output = subprocess.check_output(command, shell=True, stderr=subprocess.STDOUT)
        return output.decode()
    except subprocess.CalledProcessError as e:
        print("Error executing command:", e.cmd)
        return e.output.decode()

def check_and_install_package(package_name):
    """Check if a Python package is installed and offer to install it if not."""
    try:
        subprocess.check_call([sys.executable, "-m", "pip", "show", package_name])
        print(f"{package_name} is installed.")
    except subprocess.CalledProcessError:
        print(f"{package_name} is not installed.")
        user_input = input(f"Do you want to install {package_name}? (y/n): ").strip().lower()
        if user_input == 'y':
            print("Installing package...")
            install_command = f"pip install {package_name}"
            print(run_command(install_command))
        else:
            print("The package is required to run this script.")
            sys.exit(1)

check_and_install_package('prompt_toolkit')

def choose_file():
    """Let the user choose a file interactively using fzf."""
    file_path = run_command("fzf --preview 'bat --style=grid --color=always {}'")
    return file_path.strip()

def get_action():
    """Prompt the user to choose an action."""
    actions = ['display', 'save']
    action_completer = WordCompleter(actions, ignore_case=True)
    action = prompt("Do you want to display or save the file output? ", completer=action_completer)
    return action.lower()

def choose_output_file():
    """Prompt the user to choose the output file path using tab completion."""
    path_completer = PathCompleter(only_directories=False, expanduser=True)
    output_path = prompt("Enter the path to save the output file: ", completer=path_completer)
    return output_path

def main():
    file_path = choose_file()
    if not file_path:
        print("No file selected.")
        return

    action = get_action()
    if action == 'display':
        os.system(f"bat --style=grid {file_path}")
    elif action == 'save':
        output_path = choose_output_file()
        if output_path:
            run_command(f"bat --style=grid --paging=never {file_path} > {output_path}")
            print(f"Output saved to {output_path}")
        else:
            print("No output file path provided.")
    else:
        print("Invalid action.")

if __name__ == "__main__":
    main()

