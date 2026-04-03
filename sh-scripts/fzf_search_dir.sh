#!/usr/bin/env bash

fzf --height 40% --layout reverse --info inline --border \
  --preview 'file {}' --preview-window up,1,border-horizontal \
  --bind 'ctrl-/:change-preview-window(50%|hidden|)' \
  --color 'fg:#bbccdd,fg+:#ddeeff,bg:#334455,preview-bg:#223344,border:#778899'
