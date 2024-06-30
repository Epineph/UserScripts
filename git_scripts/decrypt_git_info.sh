#!/bin/bash

# Decrypt the GPG file and source the information
eval $(gpg --quiet --batch --decrypt ~/.git_info/git_info.gpg | sed 's/^/export /')

# Configure Git with the decrypted user name and email
git config --global user.name "$username"
git config --global user.email "$email"

