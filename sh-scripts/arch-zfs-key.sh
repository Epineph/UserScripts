#!/usr/bin/env bash

sudo pacman-key --init
sudo pacman-key --populate archlinux

sudo pacman-key -r  3A9917BF0DED5C13F69AC68FABEC0A1208037BE9

sudo pacman-key --lsign-key \
   3A9917BF0DED5C13F69AC68FABEC0A1208037BE9

