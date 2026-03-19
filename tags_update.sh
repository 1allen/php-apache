#!/bin/bash

# Function to convert branch name to tag name
convert_branch_to_tag() {
    local branch_name="$1"
    local version="${branch_name#php}" # Remove the 'php' prefix
    echo "${version:0:1}.${version:1:1}" # Transform '81' to '8.1'
}

# Fetch the latest changes from the remote
git fetch --all

# Save the current branch we're on
CURRENT_BRANCH=$(git branch | sed -n -e 's/^\* \(.*\)/\1/p')

# Get the list of branches starting with 'php' but exclude 'latest'
BRANCHES=$(git branch -r | grep 'origin/php' | grep -v 'origin/latest' | sed 's/origin\///')

# Loop through each branch and update its tag
for branch in $BRANCHES
do
    echo "Processing branch: $branch"

    # Convert branch name to tag name
    tag=$(convert_branch_to_tag "$branch")

    # Checkout the branch
    git checkout "$branch"

    # Create a new tag or move the existing tag to the current HEAD
    git tag -f "$tag" HEAD

    # Delete the tag from the remote
    git push origin --delete "$tag"

    # Push the tag to the remote
    git push origin "$tag"
done

git checkout "$CURRENT_BRANCH"

echo "Tag update complete."
