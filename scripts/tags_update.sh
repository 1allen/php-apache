#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/php-branches.conf"

DRY_RUN=1
INCLUDE_LEGACY=0

convert_branch_to_tag() {
    local branch_name="$1"
    local version="${branch_name#php}"
    echo "${version:0:1}.${version:1}"
}

run_cmd() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "Dry run: $*"
        return 0
    fi

    "$@"
}

usage() {
    cat <<'EOF'
Usage:
  bash scripts/tags_update.sh [--legacy]
  bash scripts/tags_update.sh --apply [--legacy]

By default this prints the tag actions it would take for supported PHP branches
that exist on origin. Use --apply to push the tag updates.

Deprecated PHP 7 branches are intentionally skipped unless --legacy is provided
for critical maintenance.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)
            DRY_RUN=0
            ;;
        --legacy)
            INCLUDE_LEGACY=1
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

git -C "$ROOT_DIR" fetch --all --tags

target_branches=("${SUPPORTED_PHP_BRANCHES[@]}")
if [[ "$INCLUDE_LEGACY" -eq 1 ]]; then
    target_branches+=("${LEGACY_PHP_BRANCHES[@]}")
fi

for branch in "${target_branches[@]}"; do
    if ! git -C "$ROOT_DIR" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        echo "Skipping $branch: missing origin/$branch"
        continue
    fi

    tag="$(convert_branch_to_tag "$branch")"
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
