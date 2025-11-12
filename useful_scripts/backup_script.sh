#!/usr/bin/env bash
set -euo pipefail

# Display usage help.
show_usage() {
cat << 'EOF'
Usage: $(basename "$0") [OPTION] SCRIPT_FILE

Options:
  -b, --backup       Move the script file to a backup folder (remove original).
  -c, --make-copy    Copy the script file to a backup folder (retain original).
  -h, --help         Display this help and exit.

Examples:
  $(basename "$0") -b my_script.sh
  $(basename "$0") --make-copy ./another_script.sh
EOF
}

# Parse command line options.
ARGS=$(getopt -o bch --long backup,make-copy,help -n "$(basename "$0")" -- "$@")
if [ $? -ne 0 ]; then
    show_usage
    exit 1
fi
eval set -- "$ARGS"

MODE=""
while true; do
    case "$1" in
        -b|--backup)
            if [ -n "${MODE:-}" ]; then
                echo "Error: Only one of --backup or --make-copy may be specified." >&2
                show_usage
                exit 1
            fi
            MODE="backup"
            shift
            ;;
        -c|--make-copy)
            if [ -n "${MODE:-}" ]; then
                echo "Error: Only one of --backup or --make-copy may be specified." >&2
                show_usage
                exit 1
            fi
            MODE="make-copy"
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Unknown option: $1" >&2
            show_usage
            exit 1
            ;;
    esac
done

if [ "$#" -ne 1 ]; then
    echo "Error: You must supply exactly one script file as an argument." >&2
    show_usage
    exit 1
fi

SCRIPT_FILE="$1"

if [ ! -f "$SCRIPT_FILE" ]; then
    echo "Error: File '$SCRIPT_FILE' does not exist or is not a regular file." >&2
    exit 1
fi

BACKUP_BASE="$HOME/.backup_scripts"
DATE_FOLDER=$(date +%F)
DEST_DIR="$BACKUP_BASE/$DATE_FOLDER"

mkdir -p "$DEST_DIR"

FILENAME=$(basename "$SCRIPT_FILE")
DEST_FILE="$DEST_DIR/$FILENAME"

if [ "$MODE" = "backup" ]; then
    mv "$SCRIPT_FILE" "$DEST_FILE"
    echo "Backup complete: '$SCRIPT_FILE' has been moved to '$DEST_FILE'."
elif [ "$MODE" = "make-copy" ]; then
    cp "$SCRIPT_FILE" "$DEST_FILE"
    echo "Copy complete: '$SCRIPT_FILE' has been copied to '$DEST_FILE'."
else
    echo "Error: No mode specified. Use --backup or --make-copy." >&2
    show_usage
    exit 1
fi

exit 0

