#!/bin/bash

# Define sections
HELP_SECTION=$(cat << 'EOF'
# Function to display usage
usage() {
    cat << HELP
Usage: $0 [-d | --directory <directory>] <file1> <file2> ... <fileN>
Options:
    -d, --directory  Specify the directory for backup.
    -h, --help       Display this help message.
HELP
}
EOF
)

CASE_SNIPPET=$(cat << 'EOF'
# Case statement snippet
case "$1" in
    start)
        echo "Starting..."
        ;;
    stop)
        echo "Stopping..."
        ;;
    restart)
        echo "Restarting..."
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac
EOF
)

FOR_LOOP=$(cat << 'EOF'
# For loop snippet
for i in {1..10}; do
    echo "Iteration \$i"
done
EOF
)

BOOLEAN_LOGIC=$(cat << 'EOF'
# Boolean logic snippet
if [[ "$var" == "true" ]]; then
    echo "Variable is true"
else
    echo "Variable is false"
fi
EOF
)

# Function to show usage
show_usage() {
    echo "Usage: $0 <file> <line_number> <section> [start_line] [end_line]"
    echo "Sections:"
    echo "    help           Insert help section"
    echo "    delete         Delete specified range"
    echo "    case           Insert case-in snippet"
    echo "    for            Insert for loop snippet"
    echo "    boolean        Insert boolean logic snippet"
    exit 1
}

# Function to delete lines
delete_lines() {
    if [[ -n "$START_LINE" && -n "$END_LINE" ]]; then
        sed -i "${START_LINE},${END_LINE}d" "$FILE"
    fi
}

# Function to insert sections
insert_section() {
    tmpfile=$(mktemp)
    head -n $(($LINE_NUMBER - 1)) "$FILE" > "$tmpfile"
    echo "$SECTION_CONTENT" >> "$tmpfile"
    tail -n +$LINE_NUMBER "$FILE" >> "$tmpfile"
    mv "$tmpfile" "$FILE"
    echo "Inserted $SECTION section at line $LINE_NUMBER in $FILE."
}

# fzf_edit function to select files and perform actions
fzf_edit() {
    local bat_style='--color=always --line-range :500'
    if [[ $1 == "no_line_number" ]]; then
        bat_style+=' --style=grid'
    fi

    local files
    files=$(fd --type f | fzf --preview "bat $bat_style {}" --preview-window=right:60%:wrap -m)
    if [[ -z $files ]]; then
        echo "No files selected."
        return
    fi

    echo "Selected files: $files"

    local action
    echo "Choose an action: insert, delete"
    read -r action

    case "$action" in
        insert)
            local line_number
            echo "Enter the line number to insert at:"
            read -r line_number

            local section
            echo "Choose a section to insert: help, case, for, boolean"
            read -r section

            for file in $files; do
                LINE_NUMBER="$line_number"
                FILE="$file"
                case "$section" in
                    help)
                        SECTION_CONTENT="$HELP_SECTION"
                        ;;
                    case)
                        SECTION_CONTENT="$CASE_SNIPPET"
                        ;;
                    for)
                        SECTION_CONTENT="$FOR_LOOP"
                        ;;
                    boolean)
                        SECTION_CONTENT="$BOOLEAN_LOGIC"
                        ;;
                    *)
                        echo "Unknown section: $section"
                        return
                        ;;
                esac
                insert_section
            done
            ;;
        delete)
            local start_line
            local end_line
            echo "Enter the start line number to delete from:"
            read -r start_line
            echo "Enter the end line number to delete to:"
            read -r end_line

            for file in $files; do
                START_LINE="$start_line"
                END_LINE="$end_line"
                FILE="$file"
                delete_lines
                echo "Deleted lines $START_LINE to $END_LINE in $FILE."
            done
            ;;
        *)
            echo "Unknown action: $action"
            ;;
    esac
}

# Check arguments
if [[ $# -eq 0 ]]; then
    fzf_edit
    exit 0
elif [[ $# -lt 3 ]]; then
    show_usage
fi

FILE="$1"
LINE_NUMBER="$2"
SECTION="$3"
START_LINE="$4"
END_LINE="$5"

# Check if file exists
if [[ ! -f "$FILE" ]]; then
    echo "Error: File $FILE not found."
    exit 1
fi

# Determine section content
case "$SECTION" in
    help)
        SECTION_CONTENT="$HELP_SECTION"
        ;;
    case)
        SECTION_CONTENT="$CASE_SNIPPET"
        ;;
    for)
        SECTION_CONTENT="$FOR_LOOP"
        ;;
    boolean)
        SECTION_CONTENT="$BOOLEAN_LOGIC"
        ;;
    delete)
        delete_lines
        echo "Deleted lines $START_LINE to $END_LINE in $FILE."
        exit 0
        ;;
    *)
        echo "Error: Unknown section $SECTION."
        show_usage
        ;;
esac

# Show preview
echo "Preview of $FILE around line $LINE_NUMBER:"
LINE_BEFORE=$(($LINE_NUMBER - 1))
LINE_AFTER=$(($LINE_NUMBER + 1))
sed -n "${LINE_BEFORE},${LINE_AFTER}p" "$FILE"

# Insert section content
insert_section

