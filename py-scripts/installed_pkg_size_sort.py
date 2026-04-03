pacman -Qi \
  | awk -F ': +' '
      /^Name/           { pkg = $2 }
      /^Installed Size/ { printf "%-30s %s%s\n", pkg, $2, $3 }
    ' \
  | sort -hr -k2 \
  | sed -E 's/([0-9.]+)(KiB|MiB|GiB)$/\1 \2/'

