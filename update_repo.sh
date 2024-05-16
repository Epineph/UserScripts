#!/bin/bash

# Prompt user for a commit message
echo "Enter the commit message:"
read -r COMMIT_MESSAGE

# Add all changes to the repository
git add .

# Commit the changes with the provided message
git commit -m "$COMMIT_MESSAGE"

# Push the changes to the main branch
git push origin main

echo "Changes committed and pushed successfully."

