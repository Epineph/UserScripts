#!/bin/bash

# Neovim Setup Script with Package Checks
# This script automates the installation and configuration of Neovim with desired plugins and settings.
# It checks for required packages and suggests installing missing packages.

help() {
    cat << EOF
Usage: ${0##*/} [-h]

This script sets up Neovim with a custom configuration on Arch Linux. It installs necessary packages,
configures vim-plug for plugin management, and applies settings for syntax highlighting, indentation, and visual enhancements.

Options:
    -h  Display this help and exit

Examples:
    ./nvim_setup.sh   Run the script to install and configure Neovim.
EOF
}

# Parse options
while getopts "h" opt; do
    case ${opt} in
        h)
            help
            exit 0
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            exit 1
            ;;
    esac
done

# Check for required packages
required_packages=("neovim" "python-neovim" "git" "curl")

missing_packages=()
for pkg in "${required_packages[@]}"; do
    if ! type "$pkg" > /dev/null 2>&1; then
        missing_packages+=("$pkg")
    fi
done

if [ ${#missing_packages[@]} -ne 0 ]; then
    echo "The following required packages are missing:"
    for pkg in "${missing_packages[@]}"; do
        echo "  - $pkg"
    done
    echo "Please install them using your preferred package manager and re-run the script."
    exit 1
fi

# Update system and install required packages if not already installed
echo "Updating system and installing necessary packages..."
sudo pacman -Syu --noconfirm
for pkg in "${missing_packages[@]}"; do
    sudo pacman -S "$pkg" --noconfirm
done

# Install vim-plug
echo "Installing vim-plug..."
curl -fLo ~/.local/share/nvim/site/autoload/plug.vim --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

# Create Neovim configuration directory and file
echo "Creating Neovim configuration..."
mkdir -p ~/.config/nvim
cat << 'EOF' > ~/.config/nvim/init.vim
" Specify a directory for plugins
call plug#begin('~/.local/share/nvim/plugged')

" Install plugins for syntax highlighting and themes
Plug 'nvim-treesitter/nvim-treesitter', {'do': ':TSUpdate'}
Plug 'morhetz/gruvbox'
Plug 'vim-airline/vim-airline'
Plug 'vim-airline/vim-airline-themes'
Plug 'sheerun/vim-polyglot'

" Initialize plugin system
call plug#end()

" Enable syntax highlighting
syntax on

" Set colorscheme
set background=dark
colorscheme gruvbox

" Configure vim-airline
let g:airline#extensions#tabline#enabled = 1
let g:airline#extensions#tabline#formatter = 'unique_tail'

" Treesitter configuration for better syntax highlighting
lua << EOF
require'nvim-treesitter.configs'.setup {
  highlight = {
    enable = true,
  },
}
EOF

" General settings
set number                  " Show line numbers
set relativenumber          " Show relative line numbers
set expandtab               " Use spaces instead of tabs
set tabstop=2               " Number of spaces a <Tab> in the file counts for
set shiftwidth=2            " Number of spaces to use for each step of (auto)indent
set autoindent              " Copy indent from current line when starting a new line
set smartindent             " Do smart autoindenting when starting a new line
set showmatch               " Show matching brackets

" Other useful settings
set hlsearch                " Highlight searches
set incsearch               " Incremental search
set ignorecase              " Ignore case in search patterns
set smartcase               " Override 'ignorecase' if search pattern contains uppercase letters
set wildmenu                " Visual autocomplete for command menu
set wildmode=list:longest   " Command-line completion mode
set clipboard=unnamedplus   " Use system clipboard

" Key mappings for convenience
nnoremap <C-n> :NERDTreeToggle<CR>
nnoremap <C-p> :Files<CR>

" Ensure the plugins are installed
if empty(glob('~/.local/share/nvim/plugged/nvim-treesitter'))
  autocmd VimEnter * PlugInstall | source $MYVIMRC
endif
EOF

# Install the plugins
echo "Installing plugins..."
nvim +PlugInstall +qall

echo "Neovim setup complete!"
