#!/bin/bash

# Display help section
show_help() {
  cat <<EOF
Usage: $0 [OPTIONS] <TO|FROM> <src_path> <dest_path> <host_alias>

This script transfers files between your local machine and a remote machine using SCP.

Options:
  -d, --direction        Direction of transfer (TO or FROM).
  -S, --source-path      Path to the source file or directory.
  -D, --destination-path Path to the destination file or directory.
  -H, --host-alias       Environment variable name containing the remote host address.
  -h, --help             Display this help message.
  -l, --lookup           Lookup the value of the host alias.

Examples:
  Export the remote host address as an environment variable:
    export DESKTOP_PC="user@desktop_address"

  Transfer files from local to remote:
    $0 -d TO -S /path/to/local/file_or_directory -D /path/to/remote/destination -H DESKTOP_PC

  Transfer files from remote to local:
    $0 -d FROM -S /path/to/remote/file_or_directory -D /path/to/local/destination -H DESKTOP_PC

  Lookup the value of a host alias:
    $0 -l DESKTOP_PC

Note:
  Ensure the host alias is correctly set as an environment variable before running the script.
EOF
}

# Function to show the host alias value
show_host_alias() {
  local host_alias=$1
  local host_address=$(eval echo "\$$host_alias")
  
  if [[ -z "$host_address" ]]; then
    echo "No such host alias: $host_alias"
  else
    echo "Host alias $host_alias points to: $host_address"
  fi
}

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -d|--direction) direction="$2"; shift 2 ;;
    -S|--source-path) src_path="$2"; shift 2 ;;
    -D|--destination-path) dest_path="$2"; shift 2 ;;
    -H|--host-alias) host_alias="$2"; shift 2 ;;
    -l|--lookup) lookup_alias="$2"; shift 2 ;;
    -h|--help) show_help; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; show_help; exit 1 ;;
    *) break ;;
  esac
done

# If lookup option is provided
if [[ ! -z "$lookup_alias" ]]; then
  show_host_alias "$lookup_alias"
  exit 0
fi

# If positional arguments are provided and options are not set
if [[ -z "$direction" && -z "$src_path" && -z "$dest_path" && -z "$host_alias" ]]; then
  direction=$1
  src_path=$2
  dest_path=$3
  host_alias=$4
fi

# Validate the required parameters are set
if [[ -z "$direction" || -z "$src_path" || -z "$dest_path" ]]; then
  echo "Error: Missing required arguments." >&2
  show_help
  exit 1
fi

# Check if host_alias is set; if not, prompt for it
if [[ -z "$host_alias" ]]; then
  echo "Error: host_alias argument is missing." >&2
  echo "The host-pc alias requires a valid username on the host-pc and ip-address."
  read -r -p "Do you want to provide a username and ip-address for the host-pc? (y/n) " host_alias_prompt
  if [[ "$host_alias_prompt" == "y" ]]; then
    read -r -p "Please provide the username of the host-pc: " host_username
    read -r -p "Please provide the ip-address of the host-pc: " host_ip
    host_alias="${host_username}@${host_ip}"
  else
    echo "Error: Missing required argument." >&2
    show_help
    exit 1
  fi
fi

# Retrieve the actual host address from the alias
host_address=$(eval echo "\$$host_alias")
if [[ -z "$host_address" ]]; then
  host_address="$host_alias"
fi

if [[ $direction == "TO" ]]; then
  scp -r "$src_path" "${host_address}:$dest_path"
elif [[ $direction == "FROM" ]]; then
  scp -r "${host_address}:$src_path" "$dest_path"
else
  echo "Invalid direction. Use TO or FROM."
  show_help
  exit 1
fi

