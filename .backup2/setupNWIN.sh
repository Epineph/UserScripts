#!/bin/bash

NVIM_CONF_DIR="$HOME/.config/nvim"
NVIM_CONF_FILE="$HOME/.config/nvim/init.vim"
PLUG_VIM="$HOME/.local/share/nvim/site/autoload/plug.vim"
PLUG_VIM_DIR="$HOME/.local/share/nvim/site/autoload/"
PLUG_VIM_URL="https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim"

# Function to install vim-plug
install_vim_plug() {
    if [ -f "$PLUG_VIM" ]; then
        echo "File $PLUG_VIM already exists."
        read -r -p "Backup file? (y/n) and make new?" prompt
        if [ "$prompt" == "y" ]; then
            mv "$PLUG_VIM" "$PLUG_VIM_DIR/plug_backup.vim"
            curl -fLo $PLUG_VIM --create-dirs $PLUG_VIM_URL
        else
            exit 1
        fi
    else
        curl -fLo $PLUG_VIM --create-dirs $PLUG_VIM_URL
    fi
}

# Function to create Neovim configuration
create_nvim_config() {
    mkdir -p $NVIM_CONF_DIR
    chown -R $USER $NVIM_CONF_DIR

    cat << 'EOF' > $NVIM_CONF_FILE
call plug#begin('~/.vim/plugged')

" Python support
Plug 'davidhalter/jedi-vim'

" Bash support
Plug 'arzg/vim-sh'

" R support
Plug 'jalvesaq/Nvim-R'

" Linting
Plug 'dense-analysis/ale'

" Syntax highlighting and colors
Plug 'morhetz/gruvbox'
Plug 'joshdick/onedark.vim'
Plug 'arcticicestudio/nord-vim'
Plug 'ayu-theme/ayu-vim'

" File explorer
Plug 'preservim/nerdtree'

" Git integration
Plug 'tpope/vim-fugitive'

" Status line
Plug 'vim-airline/vim-airline'
Plug 'vim-airline/vim-airline-themes'

" Fuzzy finder
Plug 'junegunn/fzf', { 'do': { -> fzf#install() } }
Plug 'junegunn/fzf.vim'

" Commenting
Plug 'tpope/vim-commentary'

" Surround text objects
Plug 'tpope/vim-surround'

call plug#end()

" Enable line numbers
set number

" Set default colorscheme
colorscheme gruvbox

" Set indentation for Bash scripts
autocmd FileType sh setlocal shiftwidth=2 tabstop=2

" Enable ALE linting
let g:ale_linters = {
\   'python': ['flake8'],
\   'sh': ['shellcheck'],
\}

" Use system clipboard
set clipboard+=unnamedplus

" NERDTree settings
map <C-n> :NERDTreeToggle<CR>
autocmd vimenter * NERDTree

" Airline settings
let g:airline#extensions#tabline#enabled = 1

" FZF settings
set rtp+=~/.fzf
let g:fzf_command_prefix = 'Fzf'

EOF
}

# Install vim-plug
install_vim_plug

# Create Neovim configuration
create_nvim_config

# Install plugins
nvim +PlugInstall +qall

# Function to change the colorscheme
change_colorscheme() {
    local scheme=$1
    sed -i "s/colorscheme .*/colorscheme $scheme/" $NVIM_CONF_FILE
    echo "Colorscheme changed to $scheme. Restart nvim to see the changes."
}

# Uncomment the colorscheme you want to apply
change_colorscheme gruvbox
# change_colorscheme onedark
# change_colorscheme nord
# change_colorscheme ayu

