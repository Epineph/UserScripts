#!/usr/bin/env bash



bat \
  --style='header,snip,grid,numbers' \ --italic-text='always' --theme='gruvbox-dark' \
  --squeeze-blank --squeeze-limit='2' --force-colorization \
  --terminal-width='-1' --tabs='2' --wrap='auto' --paging='never' \
  --chop-long-lines "${HOME}/.zshrc" $HOME/.zprofile $HOME/.zsh_profile $HOME/.zshenv $HOME/.zlogin \
	.zlogout

