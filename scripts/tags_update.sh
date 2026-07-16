#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/php-branches.conf"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/release_ref.sh"

DRY_RUN=1
target_branches=()

run_cmd() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "Dry run: $*"
        return 0
    fi

    "$@"
}

die() {
    echo "Error: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  bash scripts/tags_update.sh [--apply] [branch...]

By default this prints the tag actions it would take for supported PHP branches
that exist on origin. Pass branch names explicitly for a narrower or older set.
Use --apply to push the tag updates.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)
            DRY_RUN=0
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            target_branches+=("$1")
            ;;
    esac
    shift
done

git -C "$ROOT_DIR" fetch --all --tags

if [[ ${#target_branches[@]} -eq 0 ]]; then
    target_branches=("${SUPPORTED_PHP_BRANCHES[@]}")
fi

for branch in "${target_branches[@]}"; do
    [[ "$branch" =~ $PHP_BRANCH_PATTERN ]] || die "Branch must look like php85: $branch"

    if ! git -C "$ROOT_DIR" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        echo "Skipping $branch: missing origin/$branch"
        continue
    fi

    tag="$(release_ref_branch_to_version "$branch")"
    commit_ref="origin/$branch"

    echo "Processing branch: $branch -> tag $tag"
    run_cmd git -C "$ROOT_DIR" tag -f "$tag" "$commit_ref"
    run_cmd git -C "$ROOT_DIR" push origin ":refs/tags/$tag"
    run_cmd git -C "$ROOT_DIR" push --force origin "refs/tags/$tag"
done

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Tag update dry run complete."
else
    echo "Tag update complete."
fi
