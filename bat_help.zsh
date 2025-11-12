###############################################################################
#  bat-powered help viewer for zsh
#  Drop into ~/.zsh_profile or source from there.
###############################################################################

# --------------------------- 1. Pick a viewer -------------------------------
if command -v bat > /dev/null 2>&1; then
  # Fine-tune to your exact taste …
  local -a _BATFLAGS=(
        --language=help               # treat input as generic "help"
        --theme="gruvbox-dark"
        --style="numbers,grid,header,snip"
        --italic-text="always"
        --paging=never                # stream directly; override with -p later
        --pager="less -R"             # -R keeps colour in less
        --strip-ansi --squeeze-blank  --chop-long-lines
        --tabs=2  --wrap=character
  )
  _viewer() { bat "${_BATFLAGS[@]}" -- "$@"; }
else
  _viewer() { cat -- "$@"; }          # silent fallback
fi

# --------------------------- 2. Main help shim ------------------------------
help() {
  # ── 2.1 sanity ──────────────────────────────────────────────────────────
  [[ $# -eq 0 ]] && { echo "usage: help <command|builtin|function>" >&2; return 1; }
  local cmd=$1; shift                 # preserve additional args just in case

  # ── 2.2 is it a shell builtin or function? let run-help handle it ───────
  if whence -w "$cmd" | grep -qE 'shell builtin|function'; then
    run-help "$cmd" "$@"
    return
  fi

  # ── 2.3 external command: try --help → -h → man page ────────────────────
  if command -v "$cmd" > /dev/null 2>&1; then
    if "$cmd" --help >/dev/null 2>&1; then
      "$cmd" --help 2>&1 | _viewer
    elif "$cmd" -h >/dev/null 2>&1; then
      "$cmd" -h 2>&1 | _viewer
    elif man -w "$cmd" >/dev/null 2>&1; then
      # Colourise man page through bat if available, else fall back to less.
      if command -v bat >/dev/null 2>&1; then
        MANPAGER="sh -c 'col -bx | bat --language=man --theme=\"gruvbox-dark\" \
                         --style=\"numbers,grid\" --plain'" \
        man "$cmd"
      else
        man "$cmd"
      fi
    else
      print -u2 "No help available for $cmd"
      return 1
    fi
    return $?
  fi

  print -u2 "help: command not found: $cmd"
  return 127
}

# --------------------------- 3. Key-binding (optional) ----------------------
# Hit   Ctrl-H   at the prompt → colourised help for the word under cursor.
# Comment these four lines out if you do not want the binding.
zmodload zsh/complist            # ensure completion widgets are present
help-current-word() {
  LBUFFER="${LBUFFER% *}"         # strip trailing whitespace in buffer
  local word=${(z)LBUFFER[-1]}    # last lexical token
  zle -I                          # clear screen to avoid overlap
  help "$word"
  zle reset-prompt
}
zle -N help-current-word
bindkey '^H' help-current-word    # Ctrl-H

###############################################################################
#  End of file
###############################################################################

