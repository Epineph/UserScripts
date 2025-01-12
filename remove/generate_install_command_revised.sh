#!/bin/bash

get_latest_output_file() {
    local output_dir="${1:-.}" # Default to current directory if no argument given
    local highest_num=0
    local latest_file=""
    
    for file in "$output_dir"/output_*.txt; do
        if [[ -f "$file" && ! -f "${file%.txt}.sh" ]]; then
            local num=${file##*_}
            num=${num%.txt}
            if (( num > highest_num )); then
                highest_num=$num
                latest_file=$file
            fi
        fi
    done
    
    if [[ -z "$latest_file" && -f "$output_dir/output.txt" && ! -f "$output_dir/result.sh" ]]; then
        latest_file="$output_dir/output.txt"
    fi
    
    echo "$latest_file"
}

extract_packages() {
    # This function extracts package names marked as optional dependencies
    local input_file="$1"
    
    # Extract lines that contain optional dependencies and package names
    grep -E "^\s+[^[:space:]]+:" "$input_file" | 
    sed -E 's/^\s+([^[:space:]]+):.*/\1/' |
    sort | uniq
}

main() {
    local input_file="$1"
    local output_file="$2"
    
    if [[ -z "$input_file" ]]; then
        input_file=$(get_latest_output_file)
        if [[ -z "$input_file" ]]; then
            echo "No suitable output.txt or output_n.txt file found."
            return 1
        fi
    fi
    
    if [[ -z "$output_file" ]]; then
        if [[ "$input_file" == "output.txt" ]]; then
            output_file="result.sh"
        else
            output_file="${input_file%.txt}.sh"
        fi
    fi

    # Extract package names using the helper function
    local packages=$(extract_packages "$input_file" | awk '{printf("%s ", $0)}')
    
    if [[ -z "$packages" ]]; then
        echo "No packages to install."
        echo "echo 'No packages to install.'" > "$output_file"
    else
        local install_command="yay -S $packages --sudoloop --batchinstall --asdeps"
        echo "$install_command"
        echo "#!/bin/bash" > "$output_file"
        echo "$install_command" >> "$output_file"
    fi
    
    chmod +x "$output_file"
}

main "$1" "$2"
