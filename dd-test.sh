#!/usr/bin/env bash
findmnt -T "$PWD" -o TARGET,SOURCE,FSTYPE
df -h -- "$PWD"

(
  test_file=$(mktemp -- "$PWD/.dd-bs.XXXXXXXX") || exit 1
  trap 'rm -f -- "$test_file"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  for bs in $(shuf -e 256K 1M 4M 16M 64M); do
    printf '\nbs=%s\n' "$bs"
    LC_ALL=C ionice -c 2 -n 0 /usr/bin/dd \
      if=/dev/zero of="$test_file" bs="$bs" count=8GiB \
      iflag=fullblock conv=fsync status=progress || exit 1
  done
)
