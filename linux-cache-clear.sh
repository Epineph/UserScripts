#!/usr/bin/env bash
#################################################################
# Date: 15-July-2024
# Author: Krishna Tummeti
# Website: Tech Base Hub
# Purpose: Improve System Performance: Clear Linux Cache Easily Bash Script
#################################################################
# Get memory usage as a percentage
mem_usage=$(free -m | awk 'NR==2 {print int($3*100/$2)}')
# Set threshold
threshold=80
# Check if memory usage is greater than or equal to threshold
if [[ $mem_usage -ge $threshold ]]; then
  # Clear page cache
  sync
  echo 1 >/proc/sys/vm/drop_caches
  # Clear dentries and inodes
  sync
  echo 2 >/proc/sys/vm/drop_caches
  # Clear page cache, dentries, and inodes
  sync
  echo 3 >/proc/sys/vm/drop_caches
  # Restart
  swap swapoff -a && swapon -a
else
  # Exit with status 1 if memory usage is below threshold
  exit 1
fi
