#!/usr/bin/env bash

stamp="$(date +%F_%H%M%S)"
backup_dir="$HOME/compressed-files/zsh-fix-backup-$stamp"

mkdir -p "$backup_dir"

cp -a \
  "$HOME/.zshrc" \
  "$HOME/.zsh_profile/40_plugins.zsh" \
  "$HOME/.zsh_profile/70_misc.zsh" \
  "$HOME/.zsh_profile/80_prompt.zsh" \
  "$backup_dir"/

python <<'PY'
from pathlib import Path

home = Path.home()

def patch(path, replacements):
    text = path.read_text()
    original = text

    for label, old, new in replacements:
        if old in text:
            text = text.replace(old, new, 1)
            print(f"[OK]   {path.name}: {label}")
        else:
            print(f"[SKIP] {path.name}: {label}")

    if text != original:
        path.write_text(text)
        print(f"[WRITE] {path}")
    else:
        print(f"[UNCHANGED] {path}")

# ---------------------------------------------------------------------------
# .zshrc
# ---------------------------------------------------------------------------
zshrc = home / ".zshrc"

zinit_installer_block = """### Added by Zinit's installer
if [[ ! -f $HOME/.local/share/zinit/zinit.git/zinit.zsh ]]; then
    print -P "%F{33} %F{220}Installing %F{33}ZDHARMA-CONTINUUM%F{220} Initiative Plugin Manager (%F{33}zdharma-continuum/zinit%F{220})…%f"
    command mkdir -p "$HOME/.local/share/zinit" && command chmod g-rwX "$HOME/.local/share/zinit"
    command git clone https://github.com/zdharma-continuum/zinit "$HOME/.local/share/zinit/zinit.git" && \\
        print -P "%F{33} %F{34}Installation successful.%f%b" || \\
        print -P "%F{160} The clone has failed.%f%b"
fi

source "$HOME/.local/share/zinit/zinit.git/zinit.zsh"
autoload -Uz _zinit
(( ${+_comps} )) && _comps[zinit]=_zinit
"""

patch(
    zshrc,
    [
        (
            "remove duplicate 90_startup entry",
            """  "$ZSH_PROFILE_DIR/90_git.zsh"
  "$ZSH_PROFILE_DIR/90_startup.zsh"
)
""",
            """  "$ZSH_PROFILE_DIR/90_git.zsh"
)
""",
        ),
        (
            "remove duplicate ~/.fzf.zsh sourcing",
            """[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

""",
            "",
        ),
        (
            "remove extra Zinit installer/bootstrap block",
            zinit_installer_block,
            "",
        ),
    ],
)

# ---------------------------------------------------------------------------
# 40_plugins.zsh
# ---------------------------------------------------------------------------
plugins = home / ".zsh_profile" / "40_plugins.zsh"

early_zinit_block = """ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"
[ ! -d $ZINIT_HOME ] && mkdir -p "$(dirname $ZINIT_HOME)"
[ ! -d $ZINIT_HOME/.git ] && git clone https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME"
source "${ZINIT_HOME}/zinit.zsh"
zinit ice lucid wait'0'
zinit light z-shell/zsh-fancy-completions
autoload -Uz compinit
# typeset -g _zcompdump="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump"
# command mkdir -p -- "${_zcompdump:h}" 2>/dev/null || true
# compinit -d "$_zcompdump" -C

"""

later_zinit_block = """ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"
if [[ ! -d "$ZINIT_HOME/.git" ]]; then
  command mkdir -p -- "${ZINIT_HOME:h}"
  command git clone https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME" || {
    printf '%s\\n' "[zsh_plugins] ⛔  Could not clone zinit." >&2
    return 1
  }
fi

source "$ZINIT_HOME/zinit.zsh"

"""

patch(
    plugins,
    [
        (
            "remove first duplicate Zinit/bootstrap block",
            early_zinit_block,
            "",
        ),
        (
            "remove second duplicate Zinit/bootstrap block",
            later_zinit_block,
            "",
        ),
        (
            "remove first duplicate fzf-tab load",
            """zinit ice lucid wait"0"
zinit light Aloxaf/fzf-tab

""",
            "",
        ),
        (
            "remove duplicate Starship init from plugins file",
            '[[ -x "${commands[starship]}" ]] && eval "$(starship init zsh)"\n',
            "",
        ),
    ],
)

# ---------------------------------------------------------------------------
# 70_misc.zsh
# ---------------------------------------------------------------------------
misc = home / ".zsh_profile" / "70_misc.zsh"

patch(
    misc,
    [
        (
            "remove duplicate zoxide plugin source",
            'source "/shared/repos/zoxide/zoxide.plugin.zsh"\n',
            "",
        ),
        (
            "remove second duplicate zoxide init",
            'eval $(zoxide init zsh)\n',
            "",
        ),
    ],
)
PY

printf '\n--- verification ---\n'

rg -n \
  'zinit\.zsh|z-shell/zsh-fancy-completions|Aloxaf/fzf-tab|starship init zsh|zoxide init zsh|\.fzf\.zsh|90_startup\.zsh' \
  "$HOME/.zshrc" \
  "$HOME/.zsh_profile/40_plugins.zsh" \
  "$HOME/.zsh_profile/70_misc.zsh" \
  "$HOME/.zsh_profile/80_prompt.zsh"

printf '\n--- startup test ---\n'
zsh -lic 'printf "fresh login shell started without immediate parse failure\n"'
