#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/php-branches.conf"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/git_worktree.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/image_contract.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/release_ref.sh"

trap git_worktree_transaction_cleanup EXIT

usage() {
    cat <<'EOF'
Usage:
  bash scripts/repo_sync.sh status
  bash scripts/repo_sync.sh sync-shared [--apply] [branch...]
  bash scripts/repo_sync.sh verify-image-tooling [branch...]
  bash scripts/repo_sync.sh bootstrap-version php85 [--apply]

Commands:
  status             Show configured branches, local/remote branches, shared files,
                     and advisory upstream Docker Hub tags.
  sync-shared        Sync shared files from the source branch into local PHP branches.
                     Dry-run by default. Targets supported branches only unless
                     explicit branches are provided.
                     Use --apply to create branch-local commits.
  verify-image-tooling
                     Check that supported branch Dockerfiles include the image
                     tooling expected by downstream custom images.
                     Pass branch names explicitly to check a narrower or older set.
  bootstrap-version  Create a new local PHP branch from the source branch and rewrite
                     Dockerfile.ubuntu to the requested PHP version. Dry-run by default.
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

all_configured_branches() {
    printf '%s\n' "${SUPPORTED_PHP_BRANCHES[@]}" "${LEGACY_PHP_BRANCHES[@]}"
}

branch_in_list() {
    local needle="$1"
    shift
    local item

    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done

    return 1
}

branch_exists_local() {
    git -C "$ROOT_DIR" show-ref --verify --quiet "refs/heads/$1"
}

current_branch() {
    git -C "$ROOT_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

use_worktree_as_source_branch() {
    local requested_branch="$1"
    local current="$2"

    [[ "$requested_branch" == "$BOOTSTRAP_SOURCE_BRANCH" ]] || return 1
    [[ -n "$current" ]] || return 1
    [[ "$current" == "$BOOTSTRAP_SOURCE_BRANCH" ]] && return 0
    branch_in_list "$current" "${SUPPORTED_PHP_BRANCHES[@]}" "${LEGACY_PHP_BRANCHES[@]}" && return 1

    return 0
}

print_section() {
    local title="$1"
    shift

    echo "$title"

    if [[ $# -eq 0 ]]; then
        echo "  (none)"
        return
    fi

    local item
    for item in "$@"; do
        echo "  - $item"
    done
}

print_array_section() {
    local title="$1"
    shift
    local -a items=("$@")

    if [[ "${#items[@]}" -eq 0 ]]; then
        print_section "$title"
        return
    fi

    print_section "$title" "${items[@]}"
}

load_upstream_branches() {
    if ! command -v curl >/dev/null 2>&1; then
        return
    fi

    local response
    if ! response="$(curl -fsSL --retry 3 --retry-connrefused --connect-timeout 15 "$UPSTREAM_IMAGE_TAGS_URL" 2>/dev/null)"; then
        return
    fi

    echo "$response" \
        | grep -Eo '"name":"[0-9]+\.[0-9]+"' \
        | sed -E 's/^"name":"([0-9]+\.[0-9]+)"$/php\1/' \
        | tr -d '.' \
        | sort -u
}

copy_if_changed() {
    local source_file="$1"
    local target_file="$2"

    mkdir -p "$(dirname "$target_file")"

    if [[ ! -f "$target_file" ]] || ! cmp -s "$source_file" "$target_file"; then
        cp "$source_file" "$target_file"
        return 0
    fi

    return 1
}

status_command() {
    local configured=()
    local local_branches=()
    local remote_branches=()
    local missing_local=()
    local upstream_branches=()
    local branch

    while IFS= read -r branch; do
        [[ -n "$branch" ]] && configured+=("$branch")
    done < <(all_configured_branches)

    while IFS= read -r branch; do
        [[ -n "$branch" ]] && local_branches+=("$branch")
    done < <(git -C "$ROOT_DIR" for-each-ref --format='%(refname:short)' refs/heads/php* | sort)

    while IFS= read -r branch; do
        branch="${branch#origin/}"
        [[ -n "$branch" ]] && remote_branches+=("$branch")
    done < <(git -C "$ROOT_DIR" for-each-ref --format='%(refname:short)' refs/remotes/origin/php* | sort -u)

    for branch in "${configured[@]}"; do
        branch_in_list "$branch" "${local_branches[@]}" || missing_local+=("$branch")
    done

    while IFS= read -r branch; do
        [[ -n "$branch" ]] && upstream_branches+=("$branch")
    done < <(load_upstream_branches || true)

    print_array_section "Configured PHP branches:" "${configured[@]+"${configured[@]}"}"
    print_array_section "Local PHP branches:" "${local_branches[@]+"${local_branches[@]}"}"
    print_array_section "Remote PHP branches:" "${remote_branches[@]+"${remote_branches[@]}"}"
    print_array_section "Configured branches missing locally:" "${missing_local[@]+"${missing_local[@]}"}"
    print_array_section "Shared files:" "${SHARED_FILES[@]}"

    if [[ ${#upstream_branches[@]} -gt 0 ]]; then
        local upstream_missing=()

        for branch in "${upstream_branches[@]}"; do
            branch_in_list "$branch" "${configured[@]}" || upstream_missing+=("$branch")
        done

        print_array_section "Upstream PHP branches from Docker Hub:" "${upstream_branches[@]+"${upstream_branches[@]}"}"
        print_array_section "Configured branches missing from manifest:" "${upstream_missing[@]+"${upstream_missing[@]}"}"
    else
        echo "Upstream PHP branches from Docker Hub:"
        echo "  - unavailable (network or curl not available)"
    fi
}

sync_shared_command() {
    local apply=0
    local message="chore: sync shared repo files from ${BOOTSTRAP_SOURCE_BRANCH}"
    local target_branches=()
    local source_worktree=""
    local branch
    local file
    local worktree
    local changed_files=()
    local copied_any=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --apply)
                apply=1
                ;;
            -*)
                die "Unknown sync-shared option: $1"
                ;;
            *)
                target_branches+=("$1")
                ;;
        esac
        shift
    done

    if [[ ${#target_branches[@]} -eq 0 ]]; then
        target_branches+=("${SUPPORTED_PHP_BRANCHES[@]}")
    fi

    git_worktree_transaction_begin "$ROOT_DIR"
    git_worktree_transaction_add source "$BOOTSTRAP_SOURCE_BRANCH" detached
    source_worktree="$GIT_WORKTREE_PATH"

    echo "Source branch: $BOOTSTRAP_SOURCE_BRANCH"
    print_section "Target branches:" "${target_branches[@]}"

    if [[ $apply -eq 1 ]]; then
        git_worktree_transaction_require_clean || die "Working tree must be clean before using --apply."
    else
        echo "Dry run: no branch commits will be created."
    fi

    for branch in "${target_branches[@]}"; do
        if ! branch_exists_local "$branch"; then
            echo "Skipping $branch: local branch does not exist."
            continue
        fi

        git_worktree_transaction_add "$branch" "$branch"
        worktree="$GIT_WORKTREE_PATH"
        changed_files=()

        for file in "${SHARED_FILES[@]}"; do
            if [[ ! -f "$source_worktree/$file" ]]; then
                die "Shared file missing from source branch: $file"
            fi

            if [[ $apply -eq 1 ]]; then
                if copy_if_changed "$source_worktree/$file" "$worktree/$file"; then
                    changed_files+=("$file")
                fi
            elif [[ ! -f "$worktree/$file" ]] || ! cmp -s "$source_worktree/$file" "$worktree/$file"; then
                changed_files+=("$file")
            fi
        done

        if [[ ${#changed_files[@]} -eq 0 ]]; then
            echo "$branch: already in sync."
            git_worktree_transaction_remove "$worktree"
            continue
        fi

        copied_any=1
        print_section "$branch changes:" "${changed_files[@]}"

        if [[ $apply -eq 1 ]]; then
            git_worktree_transaction_commit "$worktree" "$message" "${changed_files[@]}"
            echo "$branch: committed shared-file sync."
        fi

        git_worktree_transaction_remove "$worktree"
    done

    if [[ $apply -eq 0 && $copied_any -eq 0 ]]; then
        echo "Dry run: no shared-file drift detected."
    fi
}

verify_image_tooling_command() {
    local target_branches=()
    local branch
    local dockerfile_content
    local marker
    local missing_markers=()
    local failed=0
    local current

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -*)
                die "Unknown verify-image-tooling option: $1"
                ;;
            *)
                target_branches+=("$1")
                ;;
        esac
        shift
    done

    if [[ ${#target_branches[@]} -eq 0 ]]; then
        target_branches+=("$BOOTSTRAP_SOURCE_BRANCH")
        target_branches+=("${SUPPORTED_PHP_BRANCHES[@]}")
    fi

    print_section "Image tooling branches:" "${target_branches[@]}"
    current="$(current_branch)"

    for branch in "${target_branches[@]}"; do
        missing_markers=()

        if ! branch_exists_local "$branch"; then
            echo "$branch: missing local branch."
            failed=1
            continue
        fi

        if [[ "$branch" == "$current" ]] || use_worktree_as_source_branch "$branch" "$current"; then
            if ! dockerfile_content="$(cat "$ROOT_DIR/Dockerfile.ubuntu" 2>/dev/null)"; then
                echo "$branch: missing Dockerfile.ubuntu."
                failed=1
                continue
            fi
        elif ! dockerfile_content="$(git -C "$ROOT_DIR" show "$branch:Dockerfile.ubuntu" 2>/dev/null)"; then
            echo "$branch: missing Dockerfile.ubuntu."
            failed=1
            continue
        fi

        while IFS= read -r marker; do
            [[ -n "$marker" ]] && missing_markers+=("$marker")
        done < <(image_contract_missing_invariants "$dockerfile_content" || true)

        if [[ ${#missing_markers[@]} -eq 0 ]]; then
            echo "$branch: ok"
            continue
        fi

        failed=1
        echo "$branch: missing required image tooling markers:"
        for marker in "${missing_markers[@]}"; do
            echo "  - $marker"
        done
    done

    return "$failed"
}

bootstrap_version_command() {
    local target_branch="${1:-}"
    local apply=0
    local php_version
    local worktree=""

    [[ -n "$target_branch" ]] || die "bootstrap-version requires a target branch such as php85."
    shift || true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --apply)
                apply=1
                ;;
            *)
                die "Unknown bootstrap-version option: $1"
                ;;
        esac
        shift
    done

    [[ "$target_branch" =~ $PHP_BRANCH_PATTERN ]] || die "Target branch must look like php85."
    php_version="$(release_ref_branch_to_version "$target_branch")"

    echo "Source branch: $BOOTSTRAP_SOURCE_BRANCH"
    echo "Target branch: $target_branch"
    echo "Target PHP version: $php_version"
    echo "Dockerfile update: Dockerfile.ubuntu -> FROM webdevops/php-apache:$php_version"

    if branch_exists_local "$target_branch"; then
        echo "Local branch already exists: $target_branch"
        return 0
    fi

    if [[ $apply -eq 0 ]]; then
        echo "Dry run: would create branch $target_branch from $BOOTSTRAP_SOURCE_BRANCH and update Dockerfile.ubuntu."
        return 0
    fi

    git_worktree_transaction_begin "$ROOT_DIR"
    git_worktree_transaction_require_clean || die "Working tree must be clean before using --apply."

    git_worktree_transaction_create_branch "$target_branch" "$BOOTSTRAP_SOURCE_BRANCH"
    git_worktree_transaction_add "$target_branch" "$target_branch"
    worktree="$GIT_WORKTREE_PATH"

    perl -0pi -e "s{FROM webdevops/php-apache:[0-9]+\\.[0-9]+}{FROM webdevops/php-apache:$php_version}" "$worktree/Dockerfile.ubuntu"

    if git -C "$worktree" diff --quiet -- Dockerfile.ubuntu; then
        git_worktree_transaction_keep_branch "$target_branch"
        echo "Created $target_branch at $BOOTSTRAP_SOURCE_BRANCH without an extra bootstrap commit; Dockerfile.ubuntu already targets PHP $php_version."
        return 0
    fi

    git_worktree_transaction_commit "$worktree" "chore: bootstrap $target_branch from $BOOTSTRAP_SOURCE_BRANCH" Dockerfile.ubuntu
    git_worktree_transaction_keep_branch "$target_branch"
    echo "Created $target_branch with a bootstrap commit."
}

main() {
    local command="${1:-status}"

    case "$command" in
        status)
            shift || true
            status_command "$@"
            ;;
        sync-shared)
            shift || true
            sync_shared_command "$@"
            ;;
        verify-image-tooling)
            shift || true
            verify_image_tooling_command "$@"
            ;;
        bootstrap-version)
            shift || true
            bootstrap_version_command "$@"
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            usage >&2
            die "Unknown command: $command"
            ;;
    esac
}

main "$@"
