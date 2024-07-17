# History Configuration
HISTSIZE=100000
SAVEHIST=100000
HISTFILE=~/.zsh_history
setopt SHARE_HISTORY
setopt HIST_REDUCE_BLANKS
setopt HIST_EXPIRE_DUPS_FIRST
setopt INC_APPEND_HISTORY
setopt HIST_IGNORE_DUPS

# Git Configuration
export GITHUB_USERNAME="Epineph"



# Build Directories
export SWIG_BUILD="$HOME/repos/swig/build"
export CMAKE_BUILD="$HOME/repos/CMake/build"
export NINJA_BUILD="$HOME/repos/ninja/build"
export RE2C_BUILD="$HOME/repos/re2c/build"
export VCPKG="$HOME/repos/vcpkg"

# Zsh and Plugin Configuration
export ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit"
export GEM_DIR="$HOME/.local/share/gem/ruby/3.0.0/bin"
export CARGO_TARGET_DIR="$HOME/.cargo"
export REPOS="$HOME/repos"
export ZSH="$HOME/.oh-my-zsh"
export NVM_DIR="$HOME/.nvm"
export FZF_DIR="$HOME/.fzf"
export EMACS_LISP="$HOME/.emacs.d/lisp/"
export YARN_DIR="$HOME/.yarn"
export YARN_GLOBAL_FOLDER="$YARN_DIR/global_packages"
export NINJA_DIR="$REPOS/ninja/build"
export CARGO_BIN="$HOME/.cargo/bin"
export BAT_STYLE="default"
export FZF_BIN="$REPOS/fzf/bin"
export NEOVIM_BIN="/usr/bin/nvim"
export BAT_DIR="$REPOS/bat/target/release"
export FD_DIR="$REPOS/fd/target/release"

# Path Configuration
export PATH="$SWIG_BUILD:$CMAKE_BUILD:$NINJA_BUILD:$RE2C_BUILD:$VCPKG:$NVM_DIR:$ZINIT_HOME:$HOME/.local/bin:$GEM_DIR:$HOME/.personalBin:$REPOS/vcpkg:$HOME/bin:/usr/local/bin:$HOME/.local/share:$NINJA_DIR:$CARGO_BIN:$FZF_BIN:$BAT_DIR:$FD_DIR:$PATH"

# FZF Configuration
export FZF_DEFAULT_OPTS='--color=bg+:#3F3F3F,bg:#4B4B4B,border:#6B6B6B,spinner:#98BC99,hl:#719872,fg:#D9D9D9,header:#719872,info:#BDBB72,pointer:#E12672,marker:#E17899,fg+:#D9D9D9,preview-bg:#3F3F3F,prompt:#98BEDE,hl+:#98BC99'

# Manpath Configuration
export MANPATH="/usr/local/man:$MANPATH"

# Locale Configuration
export LANG="en_DK.UTF-8"
export LANGUAGE="en_DK.UTF-8"

# Zinit Configuration
ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"
[ ! -d $ZINIT_HOME ] && mkdir -p "$(dirname $ZINIT_HOME)"
[ ! -d $ZINIT_HOME/.git ] && git clone https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME"
source "${ZINIT_HOME}/zinit.zsh"

autoload -Uz _zinit
(( ${+_comps} )) && _comps[zinit]=_zinit

zinit light zdharma-continuum/zinit-annex-bin-gem-node
zinit for \
  light-mode zsh-users/zsh-autosuggestions \
  light-mode zdharma-continuum/fast-syntax-highlighting \
  zdharma-continuum/history-search-multi-word \
  light-mode pick"async.zsh" src"pure.zsh" sindresorhus/pure

zi ice as"program" atclone"rm -f src/auto/config.cache; ./configure" atpull"%atclone" make pick"src/vim"
zi light vim/vim

zi ice atclone"dircolors -b LS_COLORS > c.zsh" atpull'%atclone' pick"c.zsh" nocompile'!'
zi light trapd00r/LS_COLORS

zi ice as"program" make'!' atclone'./direnv hook zsh > zhook.zsh' atpull'%atclone' src"zhook.zsh"
zi light direnv/direnv

autoload -Uz compinit
compinit

zi as'null' lucid sbin wait'1' for \
  Fakerr/git-recall \
  davidosomething/git-my \
  iwata/git-now \
  paulirish/git-open \
  paulirish/git-recent \
  atload'export _MENU_THEME=legacy' \
  arzzen/git-quick-stats \
  make'install' \
  tj/git-extras \
  make'GITURL_NO_CGITURL=1' \
  sbin'git-url;git-guclone' \
  zdharma-continuum/git-url

zinit cdreplay -q

zinit light Aloxaf/fzf-tab

zi for \
  atload"zicompinit; zicdreplay" \
  blockf \
  lucid \
  wait zsh-users/zsh-completions

# Load starship theme
zi wait lucid for z-shell/zsh-fancy-completions
zinit light z-shell/F-Sy-H

zinit pack for ls_colors

zinit \
  atclone'[[ -z ${commands[dircolors]} ]] &&
  local P=${${(M)OSTYPE##darwin}:+g};
  ${P}sed -i '\''/DIR/c\DIR 38;5;63;1'\'' LS_COLORS;
  ${P}dircolors -b LS_COLORS >! clrs.zsh' \
  atload'zstyle '\'':completion:*:default'\'' list-colors "${(s.:.)LS_COLORS}";' \
  atpull'%atclone' git id-as'trapd00r/LS_COLORS' lucid nocompile'!' pick'clrs.zsh' reset for @trapd00r/LS_COLORS

# Check and Install Oh My Zsh
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  echo "Oh My Zsh is not installed. Installing..."
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

# Ryzen Adj
sudo ryzenadj --max-performance > /dev/null 2>&1

# Aliases
alias freshZsh='source $HOME/.zshrc'
alias editZsh='sudo nano $HOME/.zshrc'
alias nvimZsh='sudo nvim $HOME/.zshrc'
alias freshBash='source $HOME/.bashrc'
alias editBash='sudo nano $HOME/.bashrc'
alias nvimBash='sudo nvim $HOME/.bashrc'
alias sudoyay='yay --batchinstall --sudoloop --asdeps'
alias autoyay='yay --batchinstall --sudoloop --asdeps --noconfirm'
alias vimZsh='sudo vim ~/.zshrc'
alias getip="ip addr | grep 'inet ' | grep -v '127.0.0.1' | awk '{print \$2}' | cut -d/ -f1"
alias fzfind='fzf --print0 | xargs -0 -o nvim'
alias zsh_profile='$HOME/.zshrc'
alias nvimInit='nvim ~/.config/nvim/init.lua'

# Functions
git_push() {
  local commit_message
  local repo_url
  local sanitized_url

  if [ -z "$GITHUB_TOKEN" ]; then
    echo "Error: GITHUB_TOKEN is not set in your environment."
    return 1
  fi

  echo "Enter the commit message:"
  read -r commit_message

  git add .
  git commit -m "$commit_message"

  repo_url=$(git config --get remote.origin.url)
  sanitized_url=$(echo "$repo_url" | sed 's|https://|https://'"$GITHUB_TOKEN"'@|')

  git push "$sanitized_url" main

  echo "Changes committed and pushed successfully."
}

clone() {
  local repo=$1
  local target_dir=$REPOS

  local build_dir=~/build_src_dir
  mkdir -p "$build_dir"

  if [[ $repo == http* ]]; then
    if [[ $repo == *aur.archlinux.org* ]]; then
      git -C "$build_dir" clone "$repo"
      local repo_name=$(basename "$repo" .git)
      push
