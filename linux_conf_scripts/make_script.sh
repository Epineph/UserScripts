#!/usr/bin/env bash
#
# Name: new_script.sh
# Description:
#   Creates a new script file in the current directory with the appropriate
#   shebang line (and extension, if desired) based on the given type.
#   If the file already exists, the script warns and exits unless -f (force) is used.
#
# Usage:
#   new_script.sh [type] [filename] [-f|--force]
#
# Types (aliases):
#   sh, shellscript     -> #!/usr/bin/env bash        (extension: .sh)
#   py, python          -> #!/usr/bin/env python3     (extension: .py)
#   rb, ruby            -> #!/usr/bin/env ruby        (extension: .rb)
#   pl, perl            -> #!/usr/bin/env perl        (extension: .pl)
#   js, node            -> #!/usr/bin/env node        (extension: .js)
#
# If 'type' is omitted, it defaults to 'shellscript'.
# If 'filename' is omitted, it defaults to 'new_script', plus the matching extension.
#
# Options:
#   -h, --help       Show this help message
#   -f, --force      Overwrite the file if it already exists
#
# Examples:
#   new_script.sh          # Creates 'new_script.sh' with bash shebang
#   new_script.sh py hello # Creates 'hello.py' with python3 shebang
#   new_script.sh js       # Creates 'new_script.js' with node shebang
#

print_help() {
  help_text=$(cat << EOF
Usage: $(basename "$0") [type] [filename] [-f|--force]

Creates a new script of a specified type with an appropriate shebang line
and an (optional) extension. If arguments are omitted, the script assumes:
  - type = shellscript
  - filename = new_script
  - extension is determined by the type

Supported types:
  sh, shellscript    -> #!/usr/bin/env bash
  py, python         -> #!/usr/bin/env python3
  rb, ruby           -> #!/usr/bin/env ruby
  pl, perl           -> #!/usr/bin/env perl
  js, node           -> #!/usr/bin/env node

Options:
  -h, --help         Show this help message
  -f, --force        Overwrite existing files

Examples:
  1) new_script.sh
     -> creates "new_script.sh" with #!/usr/bin/env bash

  2) new_script.sh py hello
     -> creates "hello.py" with #!/usr/bin/env python3

  3) new_script.sh js
     -> creates "new_script.js" with #!/usr/bin/env node

EOF
)
  if command -v bat > /dev/null 2>&1; then
    export BAT_STYLE="${BAT_STYLE:-grid,header}"
    export BAT_THEME="${BAT_THEME:-TwoDark}"

    echo "$help_text" | bat --paging="never" --style="$BAT_STYLE"
  else
    echo "$help_text"
  fi
}

########################################
# Default values
########################################
default_type="shellscript"
default_filename="new_script"
force_overwrite="false"

########################################
# Parse arguments
########################################
typeset -l script_type  # -l => lowercase variable in many shells, but let's assume bash

# We will track a maximum of two positional arguments before reading options:
#   Arg1 -> script_type  (optional)
#   Arg2 -> filename     (optional)
# Then, additional flags like -f or -h.

arg_count=0
script_type=""
filename=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--force)
            force_overwrite="true"
            shift
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            # Possibly a positional argument
            # We expect at most 2 positional arguments (type, filename)
            if [[ $arg_count -eq 0 ]]; then
                script_type="$1"
                arg_count=$((arg_count + 1))
            elif [[ $arg_count -eq 1 ]]; then
                filename="$1"
                arg_count=$((arg_count + 1))
            else
                echo "Error: Too many positional arguments."
                echo "Try '$(basename "$0") --help' for usage."
                exit 1
            fi
            shift
            ;;
    esac
done

# If no type argument was given, use the default
if [[ -z "$script_type" ]]; then
    script_type="$default_type"
fi

# Convert type to lowercase just in case:
script_type="${script_type,,}"

# If no filename was given, use the default
# We'll add the extension later depending on the script type
if [[ -z "$filename" ]]; then
    filename="$default_filename"
fi

########################################
# Determine correct shebang and extension
########################################
shebang=""
extension=""

case "$script_type" in
    sh|shell|shellscript)
        shebang="#!/usr/bin/env bash"
        extension=".sh"
        ;;
    py|python)
        shebang="#!/usr/bin/env python3"
        extension=".py"
        ;;
    rb|ruby)
        shebang="#!/usr/bin/env ruby"
        extension=".rb"
        ;;
    pl|perl)
        shebang="#!/usr/bin/env perl"
        extension=".pl"
        ;;
    js|node)
        shebang="#!/usr/bin/env node"
        extension=".js"
        ;;
    *)
        # If unknown type, treat it as shellscript,
        # or you could exit with an error:
        echo "Warning: Unknown type '$script_type'. Using shellscript as default."
        shebang="#!/usr/bin/env bash"
        extension=".sh"
        ;;
esac

########################################
# Build final filename
########################################
final_filename="${filename}${extension}"

# Check if file already exists
if [[ -e "$final_filename" && "$force_overwrite" != "true" ]]; then
    echo "Error: File '$final_filename' already exists."
    echo "Use --force (-f) to overwrite."
    exit 1
fi

########################################
# Create file with basic template
########################################
{
    echo "$shebang"
    echo
    echo "# File: $final_filename"
    echo "# Created by new_script.sh on $(date)"
    echo
    echo "# Description: [Add your description here]"
    echo
} > "$final_filename"

# Make it executable
chmod +x "$final_filename"

echo "Created and made executable: $final_filename"
echo "Shebang used: $shebang"

