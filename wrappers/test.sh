#!/usr/bin/env bash

if [[ -z "$EDITOR" ]]; then
	NO_EDITOR="true"
fi

function determine_default_editor() {
	if ! command -v subl > /dev/null 2>&1; then
		if ! command -v nvim > /dev/null 2>&1; then
			DEFAULT_EDITOR="vim"
		else
			DEFAULT_EDITOR="nvim"
		fi
	else
		DEFAULT_EDITOR="subl"
	fi
	return DEFAULT_EDITOR

}

if $EDITOR; then
	$EDITOR $1
else
	determine_default_editor
	$DEFAULT_EDITOR $1
fi

