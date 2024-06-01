#!/bin/bash

# Function to get the current directory name
get_current_directory_name() {
  basename "$PWD"
}

# Prompt user for repository name
echo "Would you like to use the current directory name as the repository name? (y/n)"
read -r use_current_dir_name

if [ "$use_current_dir_name" = "y" ]; then
  REPO_NAME=$(get_current_directory_name)
else
  echo "Please enter the repository name:"
  read -r REPO_NAME
fi

# Initialize a new Git repository
git init

# Add all files to the repository
git add .

# Commit the files
git commit -m "Initial commit"

# Create a new repository on GitHub
gh repo create "$REPO_NAME" --public --source=. --remote=origin

# Push the files to the new GitHub repository
git push -u origin master

echo "Repository '$REPO_NAME' created and files uploaded successfully."

