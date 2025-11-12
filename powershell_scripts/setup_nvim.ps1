# Set variables for directories and files
$NVIM_CONF_DIR = "$HOME\AppData\Local\nvim"
$NVIM_CONF_FILE = "$NVIM_CONF_DIR\init.vim"
$PLUG_VIM = "$HOME\AppData\Local\nvim-data\site\autoload\plug.vim"
$PLUG_VIM_DIR = "$HOME\AppData\Local\nvim-data\site\autoload"
$PLUG_VIM_URL = "https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim"

# Function to take ownership and grant full control
function Take-Ownership {
    param (
        [string]$Path
    )
    
    # Take ownership
    takeown /F $Path /R /D Y

    # Grant full control to the user
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    icacls $Path /grant $user:(OI)(CI)F /T /C
}

# Function to ensure directories exist and have proper permissions
function Ensure-Directory {
    param (
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        Write-Host "Creating directory: $Path"
        New-Item -ItemType Directory -Path $Path -Force
        Take-Ownership -Path $Path
    } else {
        Write-Host "Directory already exists: $Path"
    }
}

# Function to install vim-plug
function Install-VimPlug {
    if (Test-Path $PLUG_VIM) {
        Write-Host "File $PLUG_VIM already exists."
        $prompt = Read-Host "Backup file? (y/n) and make new?"
        if ($prompt -eq "y") {
            Rename-Item -Path $PLUG_VIM -NewName "$PLUG_VIM_DIR\plug_backup.vim"
            Invoke-WebRequest -Uri $PLUG_VIM_URL -OutFile $PLUG_VIM
        } else {
            exit
        }
    } else {
        Invoke-WebRequest -Uri $PLUG_VIM_URL -OutFile $PLUG_VIM -UseBasicParsing
    }
}

# Function to create Neovim configuration
function Create-NvimConfig {
    Ensure-Directory -Path $NVIM_CONF_DIR
    $initVimContent = @"
call plug#begin('~/.vim/plugged')

" General purpose syntax highlighting
Plug 'sheerun/vim-polyglot'

" Python support
Plug 'davidhalter/jedi-vim'

" Bash support
Plug 'arzg/vim-sh'

" R support
Plug 'jalvesaq/Nvim-R'

" JavaScript and TypeScript support
Plug 'pangloss/vim-javascript'
Plug 'leafgarland/typescript-vim'
Plug 'peitalin/vim-jsx-typescript'

" Linting
Plug 'dense-analysis/ale'

" Syntax highlighting and colors
Plug 'morhetz/gruvbox'
Plug 'joshdick/onedark.vim'
Plug 'arcticicestudio/nord-vim'
Plug 'ayu-theme/ayu-vim'
Plug 'dracula/vim'
Plug 'NLKNguyen/papercolor-theme'

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

" Autocompletion
Plug 'neoclide/coc.nvim', {'branch': 'release'}

" Snippets
Plug 'honza/vim-snippets'

" Indent line
Plug 'Yggdroot/indentLine'

" Pairs of handy bracket mappings
Plug 'jiangmiao/auto-pairs'

" LSP Config and Autocomplete
Plug 'neovim/nvim-lspconfig'
Plug 'hrsh7th/nvim-cmp'
Plug 'hrsh7th/cmp-nvim-lsp'
Plug 'hrsh7th/cmp-buffer'
Plug 'hrsh7th/cmp-path'
Plug 'saadparwaiz1/cmp_luasnip'
Plug 'L3MON4D3/LuaSnip'

" Tree-sitter
Plug 'nvim-treesitter/nvim-treesitter', {'do': ':TSUpdate'}

" Telescope
Plug 'nvim-telescope/telescope.nvim', {'tag': '0.1.0'}

" Git signs
Plug 'lewis6991/gitsigns.nvim'

" Bufferline
Plug 'akinsho/bufferline.nvim', {'tag': 'v2.*'}

" Which-key
Plug 'folke/which-key.nvim'

" Sandwich
Plug 'machakann/vim-sandwich'

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
\   'javascript': ['eslint'],
\   'typescript': ['tslint'],
\}

" Use system clipboard
set clipboard+=unnamedplus

" NERDTree settings
" Toggle NERDTree with Ctrl-n
map <C-n> :NERDTreeToggle<CR>
autocmd vimenter * NERDTree

" Airline settings
" Enable tabline in airline
let g:airline#extensions#tabline#enabled = 1

" FZF settings
set rtp+=~/.fzf
" Prefix FZF commands with Fzf
let g:fzf_command_prefix = 'Fzf'

" CoC (Conqueror of Completion) settings
" Enable these CoC extensions for various languages
let g:coc_global_extensions = ['coc-pyright', 'coc-tsserver', 'coc-json', 'coc-html', 'coc-css']

" Enable indentLine plugin
let g:indentLine_enabled = 1

" Enable auto-pairs plugin
let g:auto_pairs_enabled = 1

" Keybindings
" Quick saving with Ctrl-s
nnoremap <C-s> :w<CR>

" Navigate buffers with Ctrl-h and Ctrl-l
nnoremap <C-h> :bprev<CR>
nnoremap <C-l> :bnext<CR>

" Navigate windows with Ctrl-arrow keys
nnoremap <C-j> <C-w>j
nnoremap <C-k> <C-w>k
nnoremap <C-h> <C-w>h
nnoremap <C-l> <C-w>l

" Open FZF with Ctrl-p
nnoremap <C-p> :Files<CR>

" Comment out lines with Ctrl-/
nnoremap <C-/> :Commentary<CR>

" Surround text with quotes using vim-surround
nmap ds' :call surround#delete("normal")<CR>
nmap cs' :call surround#change("normal")<CR>
nmap ys' :call surround#yank("normal")<CR>

" Which-key configuration
lua << EOF
require("which-key").setup {}
EOF

" Define custom surround for vim-surround
let g:surround_{char2nr('c')} = "\r```\1\r```"

" Define custom surround for vim-sandwich
let g:sandwich#recipes += [{
    \   'buns': ['```vim', '```'],
    \   'input': ['cv'],
    \   'filetype': ['markdown'],
    \}]

"@
    Set-Content -Path $NVIM_CONF_FILE -Value $initVimContent
}

# Ensure necessary directories are created and accessible
Ensure-Directory -Path $NVIM_CONF_DIR
Ensure-Directory -Path $PLUG_VIM_DIR

# Install vim-plug
Install-VimPlug

# Create Neovim configuration
Create-NvimConfig

# Install plugins
Start-Process -NoNewWindow -Wait nvim -ArgumentList '+PlugInstall', '+qall'

# Function to display help
function Show-Help {
    Write-Host @"
Neovim Setup Help
=================

This script sets up Neovim with a comprehensive configuration and installs a variety of useful plugins.

For more details, check the Neovim configuration file at $NVIM_CONF_FILE.
"@
}

Show-Help

