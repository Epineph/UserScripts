#!/usr/bin/env bash
###############################################################################
# process_rasi.sh
#
# 1) Reads the raw .rasi file: /home/heini/.config/rofi/themes/KooL_style-10-Fancy.rasi
# 2) AWK:
#    - Skips multi-line /* ... */ blocks
#    - Skips lines starting with '#'
#    - Skips truly empty lines
#    - Reports skip ranges to STDERR
#    - Prints kept lines to STDOUT
# 3) Then pipes the kept lines to `sed` to unify spacing
# 4) Finally, pipes the cleaned lines to `bat` for pretty printing
#
# The final `bat` output is only the lines you kept. The "Skipped lines X-Y"
# messages go to your terminal (stderr) rather than the output.
###############################################################################

RAW_FILE="/home/heini/.config/rofi/themes/KooL_style-10-Fancy.rasi"

###############################################################################
# 1) AWK: skip logic on the raw file
###############################################################################
awk '
BEGIN {
  inComment   = 0
  skipping    = 0
  skipStart   = 0
  skipEnd     = 0
}

{
  wantToSkip = 0

  # Detect the start of /* ... */ comment
  if (index($0, "/*") > 0) {
    inComment = 1
  }

  # If we are in a /* ... */ block, skip until we see "*/"
  if (inComment) {
    wantToSkip = 1
  } else {
    # Skip line if it starts with optional space + #
    if ($0 ~ /^[[:space:]]*#/) {
      wantToSkip = 1
    }
    # Skip line if it is empty
    else if (NF == 0) {
      wantToSkip = 1
    }
  }

  if (wantToSkip) {
    if (!skipping) {
      # Just started skipping
      skipping  = 1
      skipStart = NR
      skipEnd   = NR
    } else {
      # Extend the skip range
      skipEnd = NR
    }

    # If we see "*/", we end the comment block
    if (inComment && index($0, "*/") > 0) {
      inComment = 0
    }

    next
  }
  else {
    # We are not skipping this line
    if (skipping) {
      # finalize the skip range
      if (skipStart == skipEnd) {
        print "Skipped line " skipStart > "/dev/stderr"
      } else {
        print "Skipped lines " skipStart "-" skipEnd > "/dev/stderr"
      }
      skipping = 0
    }
    # Print the kept line
    print
  }
}

END {
  # If we ended in a skip region, finalize it
  if (skipping) {
    if (skipStart == skipEnd) {
      print "Skipped line " skipStart > "/dev/stderr"
    } else {
      print "Skipped lines " skipStart "-" skipEnd > "/dev/stderr"
    }
  }
}
' "$RAW_FILE" |

###############################################################################
# 2) Sed: unify whitespace
###############################################################################
sed -E '
  s/[[:space:]]+/ /g;  # collapse multiple spaces
  s/^ //;              # remove leading space
  s/ $//;              # remove trailing space
' |

###############################################################################
# 3) bat for pretty printing (numbers, syntax, etc.)
###############################################################################
bat \
  --language="CSS" \
  --style "grid,header,snip" \
  --squeeze-limit="2" \
  -m '*.py:Python' \
  -m '*.cpp:C++' \
  -m '*.sh:Bash' \
  -m '*.rasi:CSS' \
  --force-colorization \
  --italic-text="always" \
  --tabs="2" \
  --paging="never" \
  --chop-long-lines \
  --set-terminal-title \
  --wrap="auto" \
  --strip-ansi="always" \
  --theme="Monokai Extended Bright" 
