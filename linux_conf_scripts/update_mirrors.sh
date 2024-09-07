#!/bin/bash

# Help function
function show_help() {
    cat << EOF
Usage: sudo update_mirrors [OPTIONS]

Options:
  -C, --country-mirrors "COUNTRIES"  Use a custom list of countries instead of the default.
                                      Provide countries as a comma-separated list (e.g., "Denmark,Germany").
  --append "COUNTRIES"               Append additional countries to the default list for this execution only.
                                      Provide countries as a comma-separated list (e.g., "Canada,Japan").
  -L, --log-output                   Log errors and output to a file in \$HOME/.logs/reflector/YYYY-MM-DD/.
                                      The log file will be named reflector_log_n.txt.
  --dry-run                          Run reflector without saving the results to the mirrorlist.
                                      You will be prompted to save the results afterward if desired.
  -h, --help                         Show this help message and exit.

Description:
  This script updates the Arch Linux mirrorlist using the reflector utility. It allows you to customize
  the list of countries to search for mirrors, log the output, and perform a dry-run before applying changes.
  By default, it uses a predefined list of countries close to Denmark.

Examples:
  sudo update_mirrors
  sudo update_mirrors -C "Canada,Japan"
  sudo update_mirrors --append "Canada,Japan" -L
  sudo update_mirrors --dry-run
EOF
}

# Initialize flags and variables
log_output=0
dry_run=0
append_countries=()
custom_countries=0

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -C|--country-mirrors) shift; IFS=',' read -ra custom_countries <<< "$1" ;;
        --append) shift; IFS=',' read -ra append_countries <<< "$1" ;;
        -L|--log-output) log_output=1 ;;
        --dry-run) dry_run=1 ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "Unknown parameter passed: $1"; show_help; exit 1 ;;
    esac
    shift
end

# Combine default and custom countries if provided
default_countries=(
  Denmark
  Germany
  France
  Netherlands
  Sweden
  Norway
  Finland
  Austria
  Belgium
  Switzerland
  United Kingdom
  Russia
  Ukraine
  Poland
  Estonia
  Latvia
  Lithuania
)

if [[ ${#custom_countries[@]} -gt 0 ]]; then
    countries=("${custom_countries[@]}")
else
    countries=("${default_countries[@]}")
    if [[ ${#append_countries[@]} -gt 0 ]]; then
        countries+=("${append_countries[@]}")
    fi
fi

# Convert the array to a comma-separated list
countries_list=$(IFS=, ; echo "${countries[*]}")

# Prepare logging if requested
if [[ $log_output -eq 1 ]]; then
  # Check if $HOME/.logs exists; if not, create it and set ownership and permissions
  if [ ! -d "$HOME/.logs" ]; then
    mkdir "$HOME/.logs"
    sudo chown "$USER" "$HOME/.logs"
    sudo chmod 700 "$HOME/.logs"
    echo "Directory $HOME/.logs created with ownership set to $USER and permissions set to 700 (rwx------)."
  fi

  log_dir="$HOME/.logs/reflector/$(date +%Y-%m-%d)"
  mkdir -p "$log_dir"
  log_count=$(ls -1q "$log_dir" | wc -l)
  log_file="$log_dir/reflector_log_$((log_count + 1)).txt"
fi

# Run reflector with or without dry-run
reflector_command="sudo reflector --verbose \
  --country \"$countries_list\" \
  --age 24 \
  --latest 300 \
  --fastest 250 \
  --cache-timeout 1600 \
  --download-timeout 10 \
  --connection-timeout 10 \
  --sort rate \
  --threads 5"

# Additional useful reflector options:
# --protocol: Limit mirrors to specific protocols (http, https, rsync).
# --ipv4/--ipv6: Restrict to IPv4 or IPv6 addresses.
# --score: Sort mirrors by score (combination of various factors).
# --number <n>: Limit the number of mirrors saved to <n>.

if [[ $dry_run -eq 1 ]]; then
  echo "Running reflector in dry-run mode..."
  eval "$reflector_command"
  echo "Dry-run completed."
  
  # Prompt to save the output
  read -p "Do you want to save this output to the mirrorlist? (y/N): " save_choice
  if [[ "$save_choice" =~ ^[Yy]$ ]]; then
    eval "$reflector_command --save /etc/pacman.d/mirrorlist"
    echo "Mirrorlist updated successfully!"
  else
    echo "Mirrorlist update aborted."
  fi
else
  eval "$reflector_command --save /etc/pacman.d/mirrorlist 2>>\"$log_file\""

  if [[ $log_output -eq 1 ]]; then
    # Log countries used and any errors
    {
      echo "Mirrorlist updated successfully!"
      echo "Countries used: $countries_list"
    } >> "$log_file"

    echo "Mirrorlist updated successfully! Log can be found at $log_file"
  else
    echo "Mirrorlist updated successfully!"
  fi
fi

