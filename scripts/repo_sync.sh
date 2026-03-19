#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/php-branches.conf"

TMP_WORK_ROOT=""

cleanup() {
    local path

    if [[ -n "${TMP_WORK_ROOT:-}" && -d "${TMP_WORK_ROOT:-}" ]]; then
        while IFS= read -r path; do
            git -C "$ROOT_DIR" worktree remove --force "$path" >/dev/null 2>&1 || true
        done < <(git -C "$ROOT_DIR" worktree list --porcelain | awk '/^worktree / {print substr($0, 10)}' | grep "^$TMP_WORK_ROOT" || true)
        rm -rf "$TMP_WORK_ROOT"
    fi
}

trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage:
  bash scripts/repo_sync.sh status
  bash scripts/repo_sync.sh sync-shared [--apply] [branch...]
  bash scripts/repo_sync.sh bootstrap-version php85 [--apply]

Commands:
  status             Show configured branches, local/remote branches, shared files,
                     and advisory upstream Docker Hub tags.
  sync-shared        Sync shared files from the source branch into local PHP branches.
                     Dry-run by default. Use --apply to create branch-local commits.
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

branch_exists_remote() {
    git -C "$ROOT_DIR" show-ref --verify --quiet "refs/remotes/origin/$1"
}

require_clean_worktree() {
    [[ -z "$(git -C "$ROOT_DIR" status --short)" ]] || die "Working tree must be clean before using --apply."
}

php_branch_to_version() {
    local digits="${1#php}"
    printf '%s.%s\n' "${digits:0:1}" "${digits:1}"
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

load_upstream_branches() {
    if ! command -v curl >/dev/null 2>&1; then
        return
    fi

    local response
    if ! response="$(curl -fsSL "$UPSTREAM_IMAGE_TAGS_URL" 2>/dev/null)"; then
        return
    fi

    echo "$response" \
        | grep -Eo '"name":"[0-9]+\.[0-9]+"' \
        | sed -E 's/^"name":"([0-9]+\.[0-9]+)"$/php\1/' \
        | tr -d '.' \
        | sort -u
}

prepare_temp_root() {
    [[ -n "${TMP_WORK_ROOT:-}" ]] && return
    git -C "$ROOT_DIR" worktree prune >/dev/null 2>&1 || true
    TMP_WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/php-apache-sync.XXXXXX")"
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

    print_section "Configured PHP branches:" "${configured[@]}"
    print_section "Local PHP branches:" "${local_branches[@]}"
    print_section "Remote PHP branches:" "${remote_branches[@]}"
    print_section "Configured branches missing locally:" "${missing_local[@]}"
    print_section "Shared files:" "${SHARED_FILES[@]}"

    if [[ ${#upstream_branches[@]} -gt 0 ]]; then
        local upstream_missing=()

        for branch in "${upstream_branches[@]}"; do
            branch_in_list "$branch" "${configured[@]}" || upstream_missing+=("$branch")
        done

        print_section "Upstream PHP branches from Docker Hub:" "${upstream_branches[@]}"
        print_section "Configured branches missing from manifest:" "${upstream_missing[@]}"
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
            *)
                target_branches+=("$1")
                ;;
        esac
        shift
    done

    if [[ ${#target_branches[@]} -eq 0 ]]; then
        while IFS= read -r branch; do
            [[ -n "$branch" ]] && target_branches+=("$branch")
        done < <(all_configured_branches)
    fi

    prepare_temp_root
    source_worktree="$TMP_WORK_ROOT/source"
    git -C "$ROOT_DIR" worktree add --detach "$source_worktree" "$BOOTSTRAP_SOURCE_BRANCH" >/dev/null

    echo "Source branch: $BOOTSTRAP_SOURCE_BRANCH"
    print_section "Target branches:" "${target_branches[@]}"

    if [[ $apply -eq 1 ]]; then
        require_clean_worktree
    else
        echo "Dry run: no branch commits will be created."
    fi

    for branch in "${target_branches[@]}"; do
        if ! branch_exists_local "$branch"; then
            echo "Skipping $branch: local branch does not exist."
            continue
        fi

        worktree="$TMP_WORK_ROOT/$branch"
        git -C "$ROOT_DIR" worktree add "$worktree" "$branch" >/dev/null
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
            git -C "$ROOT_DIR" worktree remove --force "$worktree" >/dev/null
            continue
        fi

        copied_any=1
        print_section "$branch changes:" "${changed_files[@]}"

        if [[ $apply -eq 1 ]]; then
            git -C "$worktree" add "${changed_files[@]}"
            git -C "$worktree" -c commit.gpgsign=false commit -m "$message" >/dev/null
            echo "$branch: committed shared-file sync."
        fi

        git -C "$ROOT_DIR" worktree remove --force "$worktree" >/dev/null
    done

    if [[ $apply -eq 0 && $copied_any -eq 0 ]]; then
        echo "Dry run: no shared-file drift detected."
    fi
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

    [[ "$target_branch" =~ ^php[0-9]{2}$ ]] || die "Target branch must look like php85."
    php_version="$(php_branch_to_version "$target_branch")"

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

    require_clean_worktree
    prepare_temp_root

    git -C "$ROOT_DIR" branch "$target_branch" "$BOOTSTRAP_SOURCE_BRANCH"
    worktree="$TMP_WORK_ROOT/$target_branch"
    git -C "$ROOT_DIR" worktree add "$worktree" "$target_branch" >/dev/null

    perl -0pi -e "s{FROM webdevops/php-apache:[0-9]+\\.[0-9]+}{FROM webdevops/php-apache:$php_version}" "$worktree/Dockerfile.ubuntu"

    if git -C "$worktree" diff --quiet -- Dockerfile.ubuntu; then
        die "Bootstrapping $target_branch did not change Dockerfile.ubuntu."
    fi

    git -C "$worktree" add Dockerfile.ubuntu
    git -C "$worktree" -c commit.gpgsign=false commit -m "chore: bootstrap $target_branch from $BOOTSTRAP_SOURCE_BRANCH" >/dev/null
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
