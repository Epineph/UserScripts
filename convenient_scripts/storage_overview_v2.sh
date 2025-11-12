#!/bin/bash

# Check if required programs are installed
for cmd in pacman yay paru fzf bat; do
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

# Get detailed information for each package and extract name and size
pacman -Qi $(cat /tmp/pkglist.txt | sort | uniq) | \
    awk '/^Name/{name=$3}/^Installed Size/{size=$4;unit=$5; if(unit=="MB") size*=1024; if(unit=="GB") size*=1024*1024; print size "\t" name}' | \
    sort -rn | head -n 30 > /tmp/largest_pkgs.txt

# Display the top 30 largest packages with fzf and bat for enhanced viewing
echo "Top 30 largest installed packages by size:"
cat /tmp/largest_pkgs.txt | fzf --preview="bat --style=plain --paging=always --wrap=never --theme='TwoDark'" --preview-window=right:50%:wrap

# Clean up
rm /tmp/pkglist.txt /tmp/largest_pkgs.txt

