#!/usr/bin/env bash
# copy_with_dialog.sh  SRC  DEST
#
# Requirements: pv, dialog

src="$1"
dest="$2"
size=$(stat --printf='%s' "$src")          # total bytes → gives ETA & %.

{
    pv -n -s "$size" "$src" >"$dest"
} 2>&1 | dialog --title "Copying $(basename "$src")" \
                --gauge "Transferring data…" 10 70 0

