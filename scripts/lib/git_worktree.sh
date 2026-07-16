#!/usr/bin/env bash

GIT_WORKTREE_ROOT=""
GIT_WORKTREE_REPOSITORY=""
GIT_WORKTREE_PATH=""
GIT_WORKTREE_CREATED_BRANCHES=()

git_worktree_transaction_begin() {
    GIT_WORKTREE_REPOSITORY="$1"
    [[ -n "$GIT_WORKTREE_ROOT" ]] && return

    git -C "$GIT_WORKTREE_REPOSITORY" worktree prune >/dev/null 2>&1 || true
    GIT_WORKTREE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/php-apache-sync.XXXXXX")"
}

git_worktree_transaction_require_clean() {
    [[ -z "$(git -C "$GIT_WORKTREE_REPOSITORY" status --short)" ]]
}

git_worktree_transaction_add() {
    local name="$1"
    local ref="$2"
    local mode="${3:-attached}"

    GIT_WORKTREE_PATH="$GIT_WORKTREE_ROOT/$name"
    if [[ "$mode" == "detached" ]]; then
        git -C "$GIT_WORKTREE_REPOSITORY" worktree add --detach "$GIT_WORKTREE_PATH" "$ref" >/dev/null
    else
        git -C "$GIT_WORKTREE_REPOSITORY" worktree add "$GIT_WORKTREE_PATH" "$ref" >/dev/null
    fi
}

git_worktree_transaction_remove() {
    local path="$1"

    git -C "$GIT_WORKTREE_REPOSITORY" worktree remove --force "$path" >/dev/null
}

git_worktree_transaction_create_branch() {
    git -C "$GIT_WORKTREE_REPOSITORY" branch "$1" "$2"
    GIT_WORKTREE_CREATED_BRANCHES+=("$1")
}

git_worktree_transaction_keep_branch() {
    local kept_branch="$1"
    local branch
    local remaining=()

    for branch in "${GIT_WORKTREE_CREATED_BRANCHES[@]+"${GIT_WORKTREE_CREATED_BRANCHES[@]}"}"; do
        [[ "$branch" == "$kept_branch" ]] || remaining+=("$branch")
    done

    GIT_WORKTREE_CREATED_BRANCHES=("${remaining[@]+"${remaining[@]}"}")
}

git_worktree_transaction_commit() {
    local worktree="$1"
    local message="$2"
    shift 2

    git -C "$worktree" add "$@"
    git -C "$worktree" -c commit.gpgsign=false commit -m "$message" >/dev/null
}

git_worktree_transaction_cleanup() {
    local path
    local branch

    if [[ -n "${GIT_WORKTREE_ROOT:-}" && -d "${GIT_WORKTREE_ROOT:-}" ]]; then
        while IFS= read -r path; do
            git -C "$GIT_WORKTREE_REPOSITORY" worktree remove --force "$path" >/dev/null 2>&1 || true
        done < <(git -C "$GIT_WORKTREE_REPOSITORY" worktree list --porcelain \
            | awk '/^worktree / {print substr($0, 10)}' \
            | grep "^$GIT_WORKTREE_ROOT" || true)
        rm -rf "$GIT_WORKTREE_ROOT"
    fi

    for branch in "${GIT_WORKTREE_CREATED_BRANCHES[@]+"${GIT_WORKTREE_CREATED_BRANCHES[@]}"}"; do
        git -C "$GIT_WORKTREE_REPOSITORY" branch -D "$branch" >/dev/null 2>&1 || true
    done

    GIT_WORKTREE_ROOT=""
    GIT_WORKTREE_PATH=""
    GIT_WORKTREE_CREATED_BRANCHES=()
}
