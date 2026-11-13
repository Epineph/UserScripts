#!/usr/bin/env bash


sudo reflector --verbose \
  --country DK,SE,NO,FI,DE,NL \
  --protocol https --age 12 --completion-percent 100 \
  --sort rate --number 10 --threads 1 \
  --connection-timeout 3 --download-timeout 3 \
  --cache-timeout 0 \
  --save /etc/pacman.d/mirrorlist
