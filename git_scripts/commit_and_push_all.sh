#!/bin/bash

# Directory containing your Git repositories
REPOS_DIR=~/repos

# Commit message
COMMIT_MSG="Auto-commit changes"

# Function to commit and push changes in a Git repository
commit_and_push() {
    local repo_dir=$1
    echo "Processing repository: $repo_dir"

    # Navigate to the repository directory
    cd $repo_dir || return

    # Check if there are any changes to commit
    if [ -n "$(git status --porcelain)" ]; then
        echo "Changes detected, committing and pushing..."

        # Add all changes
        git add .

        # Commit changes with GPG signing
        git commit -S -m "$COMMIT_MSG"

        # Push changes to the remote repository
        git push
    else
        echo "No changes to commit."
    fi

    # Return to the original directory
    cd - > /dev/null
}

# Iterate over all directories in REPOS_DIR
for dir in $REPOS_DIR/*; do
    if [ -d "$dir/.git" ]; then
        commit_and_push $dir
    else
        echo "$dir is not a Git repository."
    fi
done

echo "Done processing all repositories."

