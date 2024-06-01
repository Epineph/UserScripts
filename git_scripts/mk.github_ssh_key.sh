#!/bin/bash


SSH_KEY="$HOME/.ssh/id_rsa"





# Update system package database



function check_for_missing_pkgs() {
    local install_required=false
    req_pkg=("gh" "ssh" "git" "wget")
    for pkg in "${req_pkg[@]}"; do
        if ! type "$pkg" &> /dev/null; then
            echo "$pkg was not found on your system."
            install_required=true
        fi
    done

}





function install_pkgs() {
    local needed_pkgs=("github-cli" "openssh" "git")
    local missing_pkgs=()
    for pkg in "${needed_pkgs[@]}"; do
        if ! pacman -Qi "$pkg" &> /dev/null; then
            missing_packages+=("$pkg")
        fi

    done
    if [ ${#missing_packages[@]} -ne 0 ]; then
        echo "The following packages are not installed: ${missing_packages[*]}"
        read -p "Do you want to install them? (Y/n) " -n 1 -r
        echo    # Move to a new line
        if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
            for package in "${missing_packages[@]}"; do
                yes | sudo pacman -S "$package"
                    if [ $? -ne 0 ]; then
                        echo "Failed to install $package. Aborting."
                        exit 1
                    fi
            done
        else
            echo "The following packages are required to continue:\
            ${missing_packages[*]}. Aborting."
            exit 1
        fi
    fi
}



function main() {
    local email=""
    install_pkgs
    if [[ $# -eq 0 ]]; then
        >&2 echo "No arguments provided"
        echo "To generate ssh-key, input your email-adress :"
        read answer
        if [[ -z $answer ]]; then
            echo "aborting"
        else
            email=$answer
        fi
    fi
    if [ -f "$SSH_KEY" ]; then
        echo "SSH key exists. Generate a new one and backup the old? (y/n): "
        read yn
        case $yn in
            [Yy]* )
                # Ask user for backup location choice
                echo "Choose a backup option:"
                echo "1) Default location ($HOME/.ssh_backup)"
                echo "2) Specify another location"
                read -r -p "Enter choice (1/2): " backup_choice

                case $backup_choice in
                    1)
                        BACKUP_DIR="$HOME/.ssh_backup"
                        ;;
                    2)
                        read -p -r "Enter the backup directory path: " custom_backup_dir
                        BACKUP_DIR="$custom_backup_dir"
                        ;;
                    *)
                        echo "Invalid choice. Exiting."
                        exit 1
                        ;;
                esac

            # Create backup directory if it doesn't exist
            mkdir -p "$BACKUP_DIR" || { echo "Failed to create backup directory. Exiting."; exit 1; }

            # Backup and remove existing SSH key
            echo "Backing up existing SSH key to $BACKUP_DIR..."
            # Here you can use rsync or cp command to backup the .ssh directory
            rsync -av --progress "$HOME/.ssh/" "$BACKUP_DIR/" && rm -f "$SSH_KEY"*

            echo "Old SSH key backed up. Proceeding to generate a new one."
            # Your command to generate a new SSH key goes here
            # ssh-keygen -t rsa -b 4096 -f "$SSH_KEY"
            ;;
            [Nn]* )
                echo "Exiting.."
                exit 1
            ;;
            *)
                echo "Please answer yes or no."
                exit 1
            ;;
        esac
    else
        echo "No existing SSH key found. Generating a new one."
    # Your command to generate a new SSH key goes here if one doesn't already exist
    # ssh-keygen -t rsa -b 4096 -f "$SSH_KEY"
    fi
    ssh-keygen -t rsa-sha2-512 -b 4096 -C "$answer" -f "$SSH_KEY"

}

main "$@"
# Start the ssh-agent in the background and add your SSH key
eval "$(ssh-agent -s)"
ssh-add "$SSH_KEY"

# Print the public SSH key
echo "Copy the following SSH public key and add it to your GitHub account:"
echo "--------------------------------------------------------------------------------"
cat "${SSH_KEY}.pub"
echo "--------------------------------------------------------------------------------"
