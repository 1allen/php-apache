#!/bin/bash

# Function to convert branch name to tag name
convert_branch_to_tag() {
    local branch_name="$1"
    echo "${branch_name:3:1}.${branch_name:4}"
}

# Fetch latest changes from the remote
git fetch --all

# Save current branch we're in
CURRENT_BRANCH=$(git branch | sed -n -e 's/^\* \(.*\)/\1/p')

# Getting list of branches starting with 'php'
BRANCHES=$(git branch -r | grep 'origin/php' | sed 's/origin\///')

# Loop through each branch and update its tag
for branch in $BRANCHES
do
    echo "Processing branch: $branch"

    # Convert branch name to tag name
    tag=$(convert_branch_to_tag "$branch")

    # Checkout the branch
    git checkout "$branch"

    # Create a new tag or move the existing tag to the new HEAD
    git tag -f "$tag" HEAD

    # Delete the tag from remote
    git push origin --delete "$tag"

    # Push the tag to remote
    git push origin "$tag"
done

git checkout "$CURRENT_BRANCH"

echo "Tag update complete."
