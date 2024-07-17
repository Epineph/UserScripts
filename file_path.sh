#! /bin/sh
# Function to display usage instructions
show_help() {
    cat << EOF
Usage: $0 -D | --destination /path/to/file -S | --search /path/to/directory/to/search -R | --recursive

Options:
  -f, --full-path, --file-dir     Perform a local file transfer
  -S, --search, --search-dir      search specific directory
      --depth, --search-depth     Depth to search in given directory
  -R, --recursive                 Perform search recursively in dir

EOF
    exit 1
}

if [ $? -ne 0 ]; then
    show_help
fi


echo "$(cd "$(dirname -- "$1")" >/dev/null; pwd -P)/$(basename -- "$1")"


