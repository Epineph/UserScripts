#!/bin/bash

# List directories by disk usage
dir_list=$(du -sh * | sort -hr)

# Enumerate the list and store it in a variable
enumerated_list=$(echo "$dir_list" | awk '{print NR ": " $0}')

# Display the enumerated list and allow the user to select directories to delete
echo "Select directories to delete (e.g., 1 2 4-6):"
echo "$enumerated_list"
read -p "Enter selection: " selection

# Extract the selected directories based on user input
selected_dirs=$(echo "$enumerated_list" | awk -v sel="$selection" '
BEGIN {
    split(sel, selections, /[ ,]+/)
}
{
    for (i in selections) {
        if (NR == selections[i] || (selections[i] ~ /-/ && NR >= substr(selections[i], 1, index(selections[i], "-")-1) && NR <= substr(selections[i], index(selections[i], "-")+1))) {
            print $2
        }
    }
}')

# Calculate total space to be freed
total_space=$(echo "$selected_dirs" | xargs du -shc | grep total | awk '{print $1}')

# Confirm the deletion with the user
echo "You have selected the following directories:"
echo "$selected_dirs"
echo "Total space to be recovered: $total_space"
read -p "Are you sure you want to delete these directories? (y/n): " confirm

# If confirmed, delete the directories
if [[ $confirm == "y" ]]; then
    echo "$selected_dirs" | xargs rm -rf
    echo "Directories deleted. $total_space has been freed."
else
    echo "Operation canceled."
fi

