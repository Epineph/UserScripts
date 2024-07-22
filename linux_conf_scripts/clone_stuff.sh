#!/bin/bash

sudo pacman -S --needed git github-cli

AUR="false"
GIT="true"

repo_dir="$HOME/repos"

AUR_URL="https://aur.archlinux.org"
GIT_URL="https://github.com"

GIT_USERNAMES=("Epineph" "sharkdp" "JaKooLit" "ocaml" "openssl")
REPOS=("UserScripts" "generate_install_command" "ocaml" "openssl" \
    "my_zshrc" "nvim_conf" "yay" "paru" "Arch-Hyprland" "fd" "bat")
FULL_URL=()
USERNAME_REPO=()
clone_URL=""

if [[ ! -d "$repo_dir" ]]; then
    sudo mkdir -p "$repo_dir"
    sudo chown -R $USER "$repo_dir"
    sudo chmod -R u+rwx "$repo_dir"
fi

function generate_full_urls() {
    local user_repo=""
    local repo_url=""
    local repo_site=""
    local git_name=""
    
    for repository in "${REPOS[@]}"; do
        if [[ "$repository" == "yay" ]] || [[ "$repository" == "paru" ]]; then
            repo_site=$AUR_URL
            repo_url="$repo_site/$repository.git"
            FULL_URL+=("$repo_url")
            echo "$repo_url"
        else
            repo_site=$GIT_URL
            if [[ "$repository" == "UserScripts" ]] || [[ "$repository" == "generate_install_command" ]] || [[ "$repository" == "my_zshrc" ]] || [[ "$repository" == "nvim_conf" ]]; then
                git_name=${GIT_USERNAMES[0]}
            elif [[ "$repository" == "ocaml" ]]; then
                git_name=${GIT_USERNAMES[3]}
            elif [[ "$repository" == "openssl" ]]; then
                git_name=${GIT_USERNAMES[4]}
            elif [[ "$repository" == "Arch-Hyprland" ]]; then
                git_name=${GIT_USERNAMES[2]}
            elif [[ "$repository" == "bat" ]] || [[ "$repository" == "fd" ]]; then
                git_name=${GIT_USERNAMES[1]}
            fi
            
            user_repo="$git_name/$repository"
            repo_url="$repo_site/$user_repo.git"
            FULL_URL+=("$repo_url")
            echo "$repo_url"
        fi
    done
}

generate_full_urls

for url in "${FULL_URL[@]}"; do
    echo "$url $repo_dir/$(basename "$url" .git)"
done

