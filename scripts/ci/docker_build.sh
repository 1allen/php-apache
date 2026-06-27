#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

DOCKERFILE_PATH="${DOCKERFILE_PATH:-Dockerfile.ubuntu}"
BUILD_CONTEXT="${BUILD_CONTEXT:-.}"
DOCKER_USERNAME="${DOCKER_USERNAME:-1allen}"
IMAGE_NAME="${IMAGE_NAME:-php-apache}"
BUILDER_IMAGE="${BUILDER_IMAGE:-spritsail/debian-builder:latest}"
CI_GIT_BRANCH="${CI_GIT_BRANCH:-${SEMAPHORE_GIT_BRANCH:-${CIRCLE_BRANCH:-}}}"
CI_GIT_TAG="${CI_GIT_TAG:-${SEMAPHORE_GIT_TAG_NAME:-${CIRCLE_TAG:-}}}"
CI_GIT_REF_TYPE="${CI_GIT_REF_TYPE:-${SEMAPHORE_GIT_REF_TYPE:-${GITHUB_REF_TYPE:-}}}"
CI_DOCKER_MODE="${CI_DOCKER_MODE:-build}"
CI_DOCKER_IMAGE_ARCHIVE="${CI_DOCKER_IMAGE_ARCHIVE:-.ci-image/${IMAGE_NAME}.tar.gz}"
export DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-1}"

if [[ -z "$CI_GIT_BRANCH" && "${GITHUB_REF_TYPE:-}" == "branch" ]]; then
    CI_GIT_BRANCH="${GITHUB_REF_NAME:-}"
fi

if [[ -z "$CI_GIT_TAG" && "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
    CI_GIT_TAG="${GITHUB_REF_NAME:-}"
fi

if [[ -z "$CI_GIT_REF_TYPE" ]]; then
    if [[ -n "$CI_GIT_TAG" ]]; then
        CI_GIT_REF_TYPE="tag"
    elif [[ -n "$CI_GIT_BRANCH" ]]; then
        CI_GIT_REF_TYPE="branch"
    fi
fi

publish_image=0
publish_tag=""
cache_from_args=()

die() {
    echo "Error: $*" >&2
    exit 1
}

docker_pull_cache_source() {
    local image_ref="$1"

    docker pull "$image_ref" || true
}

is_publishable_ref() {
    [[ -n "$publish_tag" ]]
}

if [[ -n "$CI_GIT_TAG" ]]; then
    publish_tag="$CI_GIT_TAG"
    publish_image=1
elif [[ "$CI_GIT_BRANCH" =~ ^php[0-9][0-9]$ ]]; then
    publish_tag="$CI_GIT_BRANCH"
    publish_image=1
fi

cd "$ROOT_DIR"

case "$CI_DOCKER_MODE" in
    build|publish|build-publish)
        ;;
    *)
        die "Unknown CI_DOCKER_MODE: $CI_DOCKER_MODE"
        ;;
esac

if [[ "$CI_DOCKER_MODE" == "publish" ]]; then
    is_publishable_ref || die "Publish mode requires a git tag or phpXX branch."
    [[ -f "$CI_DOCKER_IMAGE_ARCHIVE" ]] || die "Missing Docker image archive: $CI_DOCKER_IMAGE_ARCHIVE"
    [[ -n "${DOCKER_PASSWORD:-}" ]] || die "DOCKER_PASSWORD is required to publish $DOCKER_USERNAME/$IMAGE_NAME:$publish_tag."

    gzip -dc "$CI_DOCKER_IMAGE_ARCHIVE" | docker load
    echo "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USERNAME}" --password-stdin
    docker tag "$IMAGE_NAME:$publish_tag" "$DOCKER_USERNAME/$IMAGE_NAME:$publish_tag"
    docker push "$DOCKER_USERNAME/$IMAGE_NAME:$publish_tag"
    exit 0
fi

if [[ "$publish_image" -eq 0 && "$CI_GIT_BRANCH" != "latest" && "$CI_GIT_REF_TYPE" != "pull-request" ]]; then
    echo "Non-publish branch push: skipping Docker build"
    exit 0
fi

if [[ "$publish_image" -eq 1 ]]; then
    docker_pull_cache_source "$DOCKER_USERNAME/$IMAGE_NAME:$publish_tag"
    cache_from_args+=(--cache-from "$DOCKER_USERNAME/$IMAGE_NAME:$publish_tag")
fi

docker_pull_cache_source "$DOCKER_USERNAME/$IMAGE_NAME:latest"
docker_pull_cache_source "$BUILDER_IMAGE"
cache_from_args+=(--cache-from "$DOCKER_USERNAME/$IMAGE_NAME:latest")
cache_from_args+=(--cache-from "$BUILDER_IMAGE")

build_args=(
    --pull
    --build-arg BUILDKIT_INLINE_CACHE=1
    "${cache_from_args[@]}"
    -f "$DOCKERFILE_PATH"
)

if [[ "$publish_image" -eq 1 ]]; then
    build_args+=(-t "$IMAGE_NAME:$publish_tag")
fi

docker build "${build_args[@]}" "$BUILD_CONTEXT"

if [[ "$publish_image" -eq 1 && "$CI_DOCKER_MODE" == "build-publish" ]]; then
    [[ -n "${DOCKER_PASSWORD:-}" ]] || die "DOCKER_PASSWORD is required to publish $DOCKER_USERNAME/$IMAGE_NAME:$publish_tag."
    echo "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USERNAME}" --password-stdin
    docker tag "$IMAGE_NAME:$publish_tag" "$DOCKER_USERNAME/$IMAGE_NAME:$publish_tag"
    docker push "$DOCKER_USERNAME/$IMAGE_NAME:$publish_tag"
elif [[ "$publish_image" -eq 1 ]]; then
    mkdir -p "$(dirname "$CI_DOCKER_IMAGE_ARCHIVE")"
    docker save "$IMAGE_NAME:$publish_tag" | gzip -1 > "$CI_DOCKER_IMAGE_ARCHIVE"
    echo "Saved Docker image artifact: $CI_DOCKER_IMAGE_ARCHIVE"
else
    echo "Build-only branch: not publishing image"
fi
