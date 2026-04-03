#!/usr/bin/env bash

curl -fLo ~/.vim/autoload/plug.vim --create --dirs \
  https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

sh -c 'curl -fLo "${XDG_DATA_HOME:-$HOME/.local/share}"/nvim/site/autoload/plug.vim --create-dirs \
  https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim'

# 2. Add a vim-plug section to your ~/.vimrc (or ~/.config/nvim/init.vim for Neovim)
#
#   call plug#begin()
#
#   List your plugins here
#   Plug 'tpope/vim-sensible'
