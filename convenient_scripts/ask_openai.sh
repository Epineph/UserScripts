#!/bin/bash

# Function to display usage
usage() {
    echo "Usage: $0 --file <file_path> [--question \"your question\"]"
    exit 1
}

# Check if the required arguments are provided
if [ "$#" -lt 2 ]; then
    usage
fi

# Parse arguments
FILE=""
QUESTION=""
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --file) FILE="$2"; shift 2 ;;
        --question) QUESTION="$2"; shift 2 ;;
        *) echo "Unknown parameter: $1"; usage ;;
    esac
done

# Check if file is specified and exists
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
    echo "File not specified or does not exist."
    usage
fi

# Set your OpenAI API key
OPENAI_API_KEY="${OPENAI_API_KEY}"

# Check if the API key is set
if [ -z "$OPENAI_API_KEY" ]; then
    echo "Please set your OPENAI_API_KEY environment variable."
    exit 1
fi

# Read the content of the file
FILE_CONTENT=$(cat "$FILE")

# Prepare the data for the API request
SYSTEM_MESSAGE="You are an expert in Linux systems. Please provide detailed explanations for the following code with a focus on best practices and potential improvements."
PROMPT="Here is the content of the file:\n\n$FILE_CONTENT\n\nQuestion: $QUESTION"

REQUEST_DATA=$(jq -n --arg system_message "$SYSTEM_MESSAGE" --arg prompt "$PROMPT" '{
    "model": "gpt-4",
    "messages": [
        {"role": "system", "content": $system_message},
        {"role": "user", "content": $prompt}
    ]
}')

# Make the API request
RESPONSE=$(curl -s -X POST https://api.openai.com/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -d "$REQUEST_DATA")

# Extract and print the response
ANSWER=$(echo "$RESPONSE" | jq -r '.choices[0].message.content')

# Prepare the output directory
OUTPUT_DIR="$HOME/.open_ai_answers"
mkdir -p "$OUTPUT_DIR"

# Get the current date and time
CURRENT_DATE=$(date +"%m-%d-%Y")
CURRENT_TIME=$(date +"%H-%M-%S")

# Determine the script and markdown file names
SCRIPT_FILE="$OUTPUT_DIR/${CURRENT_DATE}_script_${CURRENT_TIME}_1.sh"
MARKDOWN_FILE="$OUTPUT_DIR/${CURRENT_DATE}_response_${CURRENT_TIME}_1.md"

# Ensure unique filenames
counter=1
while [[ -f "$SCRIPT_FILE" || -f "$MARKDOWN_FILE" ]]; do
    SCRIPT_FILE="$OUTPUT_DIR/${CURRENT_DATE}_script_${CURRENT_TIME}_$counter.sh"
    MARKDOWN_FILE="$OUTPUT_DIR/${CURRENT_DATE}_response_${CURRENT_TIME}_$counter.md"
    counter=$((counter + 1))
done

# Write the script file
echo "$FILE_CONTENT" > "$SCRIPT_FILE"

# Write the markdown file
{
    echo -e "# Response for script on $CURRENT_DATE at $CURRENT_TIME\n"
    echo "## Original Script:"
    echo '```sh'
    echo "$FILE_CONTENT"
    echo '```'
    echo -e "\n## AI Debug and Explanation:\n"
    echo "$ANSWER"
} > "$MARKDOWN_FILE"

echo -e "Script written to: $SCRIPT_FILE"
echo -e "Markdown response written to: $MARKDOWN_FILE"

# Prompt the user for viewing options
read -p "Do you want to view any of the files? (yes/no) " view_files
if [[ "$view_files" == "yes" ]]; then
    echo "Select an option:"
    echo "1. View script file with cat"
    echo "2. View markdown file with cat"
    echo "3. View script file with bat"
    echo "4. View markdown file with bat"
    echo "5. View script file with fzf"
    echo "6. View markdown file with fzf"
    echo "7. Open script file in editor"
    echo "8. Open markdown file in editor"
    read -p "Enter your choice (1-8): " choice

    case $choice in
        1) cat "$SCRIPT_FILE" ;;
        2) cat "$MARKDOWN_FILE" ;;
        3) bat "$SCRIPT_FILE" ;;
        4) bat "$MARKDOWN_FILE" ;;
        5) fzf --preview "bat --style=numbers --color=always --line-range :500 {}" < "$SCRIPT_FILE" ;;
        6) fzf --preview "bat --style=numbers --color=always --line-range :500 {}" < "$MARKDOWN_FILE" ;;
        7)
            read -p "Choose editor (vim/nvim/nano/code): " editor
            sudo "$editor" "$SCRIPT_FILE"
            ;;
        8)
            read -p "Choose editor (vim/nvim/nano/code): " editor
            sudo "$editor" "$MARKDOWN_FILE"
            ;;
        *) echo "Invalid choice";;
    esac
fi

