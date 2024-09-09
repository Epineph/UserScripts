#!/bin/bash

# Function to display help information
display_help() {
    cat << EOF
Usage: $0 [options]

Options:
  -n, --name <scriptname>        Specify the name of the script to be created.
  -t, --type <type>              Specify the type of the script (e.g., sh, py, md, R, rmd).
  -p, --path <path>              Specify the directory path where the script will be created.
                                 If the path does not exist, you will be prompted to create it.
                                 If omitted, the script will be created in the current directory
                                 or in the default location: \$HOME/user_scripts/<script_type>.
  -c, --current-path             Force the script to be created in the current directory.
  -h, --help                     Display this help message.

Script Types and Default Headers:
  sh   - Creates a shell script with the header: #!/bin/bash
  py   - Creates a Python script with the header: #!/usr/bin/env python3
  md   - Creates a Markdown file with a basic header.
  R    - Creates an R script.
  rmd  - Creates an R Markdown file with a basic template.

Examples:
  $0 -n build_repo -t sh
    Creates a shell script named build_repo.sh with the header #!/bin/bash.

  $0 -n analyze_data -t py -p /tmp/scripts
    Creates a Python script named analyze_data.py in the /tmp/scripts directory.

  $0 -n summary_report -t md -c
    Creates a Markdown file named summary_report.md in the current directory.

EOF
}

# Function to prompt user for input
prompt_user() {
    local prompt_message="$1"
    local user_input

    read -p "$prompt_message" user_input
    echo "$user_input"
}

# Function to create the script with the appropriate header based on type
create_script() {
    local script_path="$1"
    local script_type="$2"

    case "$script_type" in
        sh)
            echo "#!/bin/bash" > "$script_path"
            ;;
        py)
            echo "#!/usr/bin/env python3" > "$script_path"
            ;;
        md)
            echo -e "# Markdown Header\n" > "$script_path"
            ;;
        R)
            echo "# R script" > "$script_path"
            ;;
        rmd)
            echo -e "---\ntitle: \"Example\"\nauthor: \"Albert Einstein\"\noutput:\n\tpdf_document:\n\t\ttoc:true\n---\n# Header\n```{r, include=FALSE}\ninstall.packages(c(\"rmarkdown\",\"tidyverse\", \"ggplot2\"))\nlibrary(tidyverse)\n```" > "$script_path"
            ;;
        *)
            echo "Unsupported script type: $script_type"
            exit 1
            ;;
    esac

    chmod +x "$script_path"
    echo "Script created at: $script_path"
}

# Main script
script_name=""
script_type=""
script_path=""
current_path=false

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -n|--name)
            script_name="$2"
            shift
            ;;
        -t|--type)
            script_type="$2"
            shift
            ;;
        -p|--path)
            script_path="$2"
            shift
            ;;
        -c|--current-path)
            current_path=true
            ;;
        -h|--help)
            display_help
            exit 0
            ;;
        *)
            echo "Unknown parameter: $1"
            display_help
            exit 1
            ;;
    esac
    shift
end

# Validate input
if [ -z "$script_name" ]; then
    echo "Error: Script name is required."
    exit 1
fi

if [ -z "$script_type" ]; then
    echo "Error: Script type is required."
    exit 1
fi

if [ -n "$script_path" ]; then
    if [ ! -d "$script_path" ]; then
        create_dir=$(prompt_user "The specified path does not exist. Do you want to create it? (Y/n): ")
        if [[ "$create_dir" =~ ^[Yy]$ ]]; then
            mkdir -p "$script_path"
        else
            echo "Aborting."
            exit 1
        fi
    fi
else
    use_current_dir=$(prompt_user "No path specified. Create the script in the current directory? (Y/n): ")
    if [[ "$use_current_dir" =~ ^[Yy]$ ]]; then
        script_path=$(pwd)
    else
        script_path="$HOME/user_scripts/$script_type"
        if [ ! -d "$script_path" ]; then
            mkdir -p "$script_path"
        fi
    fi
fi

if [ "$current_path" = true ]; then
    script_path=$(pwd)
fi

# Create the full script path
script_full_path="$script_path/$script_name.$script_type"

# Create the script with the appropriate header
create_script "$script_full_path" "$script_type"

