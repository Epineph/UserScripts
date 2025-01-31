#!/bin/bash

repo_dir="$HOME/Downloads"
scripts_dir="$HOME/bin"
USER_SCRIPTS="$repo_dir/UserScripts"

sudo pacman -S --needed git

if [[ ! -d "$repo_dir" ]]; then
	sudo mkdir -p "$repo_dir"
fi

if [[ ! -d "$scripts_dir" ]]; then
	sudo mkdir -p "$scripts_dir"
fi



if [[ "$SHELL" == "/usr/bin/bash" || "$SHELL" == "/bin/bash" ]]; then
	echo -e "\nexport PATH=$HOME/bin:$HOME/.cargo/bin:/usr/local/bin:$PATH" | sudo tee -a $HOME/.bashrc
fi


# Ensure that the necessary commands are available
for cmd in git cut; do
    if ! command -v $cmd &> /dev/null; then
        echo "$cmd could not be found. Please install $cmd."
        exit 1
    fi
done

git_repo="https://github.com/"
aur_repo="https://aur.archlinux.org/"

repos=("Epineph/my_zshrc" "Epineph/zfsArch" "Epineph/UserScripts" "Epineph/nvim_conf" "paru" "yay")

scripts=("git_clone/clone_git.sh" "linux_conf_scripts/prepare_pc.sh" "linux_conf_scripts/reflector.sh" "building_scripts/build_project.sh" "building_scripts/build_repo.sh" "git_scripts/git_config.sh" "fd_linux_scripts/find_large_files.sh" "log_scripts/gen_log.sh" "convenient_scripts/chPerms.sh")

for repository in "${repos[@]}"; do
	if [[ "$repository" == "yay" || "$repository" == "paru" ]]; then
		git -C "$repo_dir" clone "$aur_repo/$repository"
	else
		git -C "$repo_dir" clone "$git_repo/$repository"
	fi
done

sudo chown -R "$USER" "$repo_dir"
sudo chmod -R u+rwx "$repo_dir"

 

sudo cp "$repo_dir/UserScripts/linux_conf_scripts/reflector.sh" "$script_dir/update_mirrors"
sudo cp "$repo_dir/UserScripts/git_clone/clone_git.sh" "$script_dir/clone_git"
sudo cp "$repo_dir/UserScripts/building_scripts/build_project.sh" "$script_dir/build_project"
sudo cp "$repo_dir/UserScripts/building_scripts/build_repo.sh" "$script_dir/build_repo"
sudo cp "$repo_dir/UserScripts/git_scripts/git_config.sh" "$script_dir/git_config"
sudo cp "$repo_dir/UserScripts/log_scripts/gen_log.sh" "$script_dir/gen_log"

cd "$repo_dir/my_zshrc"

#./install.sh





