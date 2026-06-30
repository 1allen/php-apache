#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKER_BUILD_SCRIPT="$ROOT_DIR/scripts/ci/docker_build.sh"

CI_GIT_BRANCH="${CI_GIT_BRANCH:-${SEMAPHORE_GIT_BRANCH:-}}"
CI_GIT_TAG="${CI_GIT_TAG:-${SEMAPHORE_GIT_TAG_NAME:-}}"
CI_GIT_REF_TYPE="${CI_GIT_REF_TYPE:-${SEMAPHORE_GIT_REF_TYPE:-}}"
export CI_GIT_BRANCH CI_GIT_TAG CI_GIT_REF_TYPE

die() {
    echo "Error: $*" >&2
    exit 1
}

load_metadata() {
    local key
    local value

    image_line=""
    cache_key=""
    publish_image=0
    artifact_name=""

    while IFS='=' read -r key value; do
        case "$key" in
            image_line)
                image_line="$value"
                ;;
            cache_key)
                cache_key="$value"
                ;;
            publish_image)
                publish_image="$value"
                ;;
            artifact_name)
                artifact_name="$value"
                ;;
        esac
    done < <("$DOCKER_BUILD_SCRIPT" metadata)

    [[ -n "$image_line" ]] || die "Unable to determine image line."
    [[ -n "$cache_key" ]] || die "Unable to determine cache key."
}

artifact_path() {
    [[ -n "$artifact_name" ]] || die "No artifact name is available for this ref."
    printf '.ci-artifacts/%s\n' "$artifact_name"
}

build_command() {
    load_metadata

    export DOCKER_BUILDX_CACHE_DIR=".cache/docker-buildx/$image_line"

    cache restore "$cache_key" || true
    "$DOCKER_BUILD_SCRIPT" build
    cache delete "$cache_key" || true
    cache store "$cache_key" "$DOCKER_BUILDX_CACHE_DIR" || true

    if [[ "$publish_image" -eq 1 ]]; then
        local path
        path="$(artifact_path)"
        "$DOCKER_BUILD_SCRIPT" save-artifact "$path"
        artifact push workflow "$path"
    fi
}

publish_command() {
    load_metadata
    [[ "$publish_image" -eq 1 ]] || die "Refusing to publish non-publish ref."

    local path
    path="$(artifact_path)"

    artifact pull workflow "$path"
    "$DOCKER_BUILD_SCRIPT" load-artifact "$path"
    "$DOCKER_BUILD_SCRIPT" publish
}

case "${1:-}" in
    build)
        build_command
        ;;
    publish)
        publish_command
        ;;
    *)
        die "Usage: $0 build|publish"
        ;;
esac
