#!/bin/bash

# Check if required programs are installed
for cmd in pacman yay paru rg fd fzf bat; do
    if ! command -v $cmd &> /dev/null; then
        echo "$cmd is not installed. Please install it and try again."
        exit 1
    fi
done

# Fetch the list of installed packages with their sizes (including AUR)
echo "Fetching package sizes..."
pacman -Qqe > /tmp/pkglist.txt
yay -Qqe >> /tmp/pkglist.txt
paru -Qqe >> /tmp/pkglist.txt
pacman -Qi $(cat /tmp/pkglist.txt | sort | uniq) | rg "Name|Installed Size" | \
    awk '/Name/ { name=$3 } /Installed Size/ { print $4 $5 "\t" name }' | \
    sed -e 's/KB//g' -e 's/MB/*1024/g' -e 's/GB/*1024*1024/g' | bc | \
    awk '{print $1 "\t" $2}' | sort -rn | head -n 30 > /tmp/largest_pkgs.txt

# Display the top 30 largest packages with fzf and bat for enhanced viewing
echo "Top 30 largest installed packages by size:"
cat /tmp/largest_pkgs.txt | fzf --preview="bat --style=plain --paging=always --wrap=never --theme='TwoDark'" --preview-window=right:50%:wrap

# Clean up
rm /tmp/pkglist.txt /tmp/largest_pkgs.txt

