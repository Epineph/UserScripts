#!/usr/bin/env bash
# showfunc.sh — Show a shell function's definition, file path, and optionally line numbers.
# Works in Bash and Zsh.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  showfunc.sh [OPTIONS] FUNCTION_NAME

Description:
  Displays the definition of a shell function currently loaded in the shell.
  Can also show the file path where it is defined and the line number range (if available).

Options:
  -p, --path       Show the file path where the function is defined (if available).
  -v, --verbose    Show the start and end line numbers of the function in the file (if available).
  -h, --help       Show this help message and exit.

Examples:
  showfunc.sh my_function
  showfunc.sh -p my_function
  showfunc.sh -p -v my_function
  showfunc.sh -v my_function

Notes:
  - Works in Bash and Zsh.
  - File path and line numbers are only available if the shell stores debug info
    (Bash usually does for sourced files; Zsh often does not for .zshrc functions).
EOF
    exit 0
}

show_path=false
show_verbose=false
func_name=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--path) show_path=true; shift ;;
        -v|--verbose) show_verbose=true; shift ;;
        -h|--help) usage ;;
        -*)
            echo "Unknown option: $1"
            usage
            ;;
        *)
            func_name="$1"
            shift
            ;;
    esac
done

if [[ -z "$func_name" ]]; then
    echo "Error: No function name provided."
    usage
fi

# Detect shell
shell_name=$(ps -p $$ -o comm=)

# Check if function exists
if [[ "$shell_name" == "zsh" ]]; then
    if ! typeset -f "$func_name" >/dev/null; then
        echo "Error: Function '$func_name' not found in current Zsh session."
        exit 1
    fi
else
    if ! declare -F "$func_name" >/dev/null; then
        echo "Error: Function '$func_name' not found in current Bash session."
        exit 1
    fi
fi

# Try to get file and line info
func_file=""
func_line=""
if [[ "$shell_name" == "bash" ]]; then
    read _ _ func_file func_line <<< "$(declare -F "$func_name")"
elif [[ "$shell_name" == "zsh" ]]; then
    # Zsh: use functions -D to get debug info (requires setopt FUNCTION_ARGZERO)
    if functions -D "$func_name" &>/dev/null; then
        func_file=$(functions -D "$func_name" | awk '{print $2; exit}')
        func_line=$(functions -D "$func_name" | awk '{print $3; exit}')
    fi
fi

# Show path if requested
if $show_path; then
    if [[ -n "$func_file" ]]; then
        echo "Defined in: $func_file"
    else
        echo "Function '$func_name' is defined in the current shell (file unknown)."
    fi
fi

# Show verbose line range if requested
if $show_verbose && [[ -n "$func_file" && -n "$func_line" && -f "$func_file" ]]; then
    start_line="$func_line"
    end_line=$(awk "NR >= $start_line && /^\}/ { print NR; exit }" "$func_file")
    if [[ -n "$end_line" ]]; then
        echo "Line range: $start_line-$end_line"
    else
        echo "Could not determine end line."
    fi
elif $show_verbose; then
    echo "Line number information not available for this function."
fi

# Show function definition
echo "----- Function Definition: $func_name -----"
if [[ "$shell_name" == "zsh" ]]; then
    typeset -f "$func_name"
else
    declare -f "$func_name"
fi

