#!/usr/bin/env bash

# Provider-neutral release-ref policy. Call release_ref_resolve before reading
# the RELEASE_REF_* result variables.

release_ref_resolve() {
    RELEASE_REF_BRANCH="${CI_GIT_BRANCH:-${SEMAPHORE_GIT_BRANCH:-${CIRCLE_BRANCH:-}}}"
    RELEASE_REF_TAG="${CI_GIT_TAG:-${SEMAPHORE_GIT_TAG_NAME:-${CIRCLE_TAG:-}}}"
    RELEASE_REF_TYPE="${CI_GIT_REF_TYPE:-${SEMAPHORE_GIT_REF_TYPE:-${GITHUB_REF_TYPE:-}}}"

    if [[ -z "$RELEASE_REF_BRANCH" && "${GITHUB_REF_TYPE:-}" == "branch" ]]; then
        RELEASE_REF_BRANCH="${GITHUB_REF_NAME:-}"
    fi

    if [[ -z "$RELEASE_REF_TAG" && "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
        RELEASE_REF_TAG="${GITHUB_REF_NAME:-}"
    fi

    if [[ -z "$RELEASE_REF_TYPE" ]]; then
        if [[ -n "$RELEASE_REF_TAG" ]]; then
            RELEASE_REF_TYPE="tag"
        elif [[ -n "$RELEASE_REF_BRANCH" ]]; then
            RELEASE_REF_TYPE="branch"
        fi
    fi

    RELEASE_REF_PUBLISH_TAG=""
    if [[ -n "$RELEASE_REF_TAG" && "$RELEASE_REF_TAG" =~ $PUBLISH_TAG_PATTERN ]]; then
        RELEASE_REF_PUBLISH_TAG="$RELEASE_REF_TAG"
    elif [[ -z "$RELEASE_REF_TAG" && "$RELEASE_REF_TYPE" != "pull-request" && "$RELEASE_REF_BRANCH" =~ $PHP_BRANCH_PATTERN ]]; then
        RELEASE_REF_PUBLISH_TAG="$RELEASE_REF_BRANCH"
    fi
}

release_ref_is_publishable() {
    [[ -n "${RELEASE_REF_PUBLISH_TAG:-}" ]]
}

release_ref_requires_build() {
    release_ref_is_publishable \
        || [[ "${RELEASE_REF_BRANCH:-}" == "$BOOTSTRAP_SOURCE_BRANCH" ]] \
        || [[ "${RELEASE_REF_TYPE:-}" == "pull-request" ]]
}

release_ref_branch_to_version() {
    local branch_name="$1"
    local digits

    [[ "$branch_name" =~ $PHP_BRANCH_PATTERN ]] || return 1
    digits="${branch_name#php}"
    printf '%s.%s\n' "${digits:0:1}" "${digits:1}"
}
