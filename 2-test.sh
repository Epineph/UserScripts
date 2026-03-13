#!/usr/bin/env bash
7z x "/home/heini/compressed-files/zsh-backup-2026-03-12_113629.7z" \
  -o"$HOME/Recycle Bin"



cat <<

bind = CTRL ALT, Q, exec, md-fence-insert
bind = CTRL ALT, R, exec, md-fence-insert r
bind = CTRL ALT, P, exec, md-fence-insert python
bind = CTRL ALT, B, exec, md-fence-insert bash
bind = CTRL ALT, J, exec, md-fence-insert javascript
bind = CTRL ALT, S, exec, md-fence-insert sql
bind = CTRL ALT, C, exec, md-fence-insert c
bind = CTRL ALT, H, exec, md-fence-insert html
