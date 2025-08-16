#!/usr/bin/env bash

countries=(
  Denmark
  Germany
  Netherlands
  Sweden
  Norway
)

countries_list=$(IFS=, ; echo "${countries[*]}")


sudo reflector --verbose --country $countries_list --age 24 --latest 15 --fastest 15 --sort rate --protocol https --connection-timeout 5 --download-timeout 10 --cache-timeout 0 --threads 4 --save /etc/pacman.d/mirrorlist
