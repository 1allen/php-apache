#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/php-branches.conf"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/release_ref.sh"

DOCKERFILE_PATH="${DOCKERFILE_PATH:-Dockerfile.ubuntu}"
BUILD_CONTEXT="${BUILD_CONTEXT:-.}"
DOCKER_USERNAME="${DOCKER_USERNAME:-$DEFAULT_DOCKER_USERNAME}"
IMAGE_NAME="${IMAGE_NAME:-$DEFAULT_IMAGE_NAME}"
BUILDER_IMAGE="${BUILDER_IMAGE:-$DEFAULT_BUILDER_IMAGE}"
CI_DOCKER_MODE="${CI_DOCKER_MODE:-build}"
export DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-1}"
cache_from_args=()

die() {
    echo "Error: $*" >&2
    exit 1
}

docker_pull_cache_source() {
    local image_ref="$1"

    docker pull "$image_ref" || true
}

case "$CI_DOCKER_MODE" in
    build|build-publish)
        ;;
    *)
        die "Unknown CI_DOCKER_MODE: $CI_DOCKER_MODE"
        ;;
esac

release_ref_resolve

if [[ "$CI_DOCKER_MODE" == "build-publish" && "$RELEASE_REF_TYPE" == "pull-request" ]]; then
    die "Refusing to publish from pull-request ref."
fi

if [[ -n "$RELEASE_REF_TAG" && -z "$RELEASE_REF_PUBLISH_TAG" && "$CI_DOCKER_MODE" == "build-publish" ]]; then
    die "Refusing to publish non-version tag: $RELEASE_REF_TAG."
fi

cd "$ROOT_DIR"

if ! release_ref_requires_build; then
    echo "Non-publish ref: skipping Docker build"
    exit 0
fi

if release_ref_is_publishable; then
    docker_pull_cache_source "$DOCKER_USERNAME/$IMAGE_NAME:$RELEASE_REF_PUBLISH_TAG"
    cache_from_args+=(--cache-from "$DOCKER_USERNAME/$IMAGE_NAME:$RELEASE_REF_PUBLISH_TAG")
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

if release_ref_is_publishable; then
    build_args+=(-t "$IMAGE_NAME:$RELEASE_REF_PUBLISH_TAG")
fi

docker build "${build_args[@]}" "$BUILD_CONTEXT"

if release_ref_is_publishable && [[ "$CI_DOCKER_MODE" == "build-publish" ]]; then
    [[ -n "${DOCKER_PASSWORD:-}" ]] || die "DOCKER_PASSWORD is required to publish $DOCKER_USERNAME/$IMAGE_NAME:$RELEASE_REF_PUBLISH_TAG."
    echo "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USERNAME}" --password-stdin
    docker tag "$IMAGE_NAME:$RELEASE_REF_PUBLISH_TAG" "$DOCKER_USERNAME/$IMAGE_NAME:$RELEASE_REF_PUBLISH_TAG"
    docker push "$DOCKER_USERNAME/$IMAGE_NAME:$RELEASE_REF_PUBLISH_TAG"
elif release_ref_is_publishable; then
    echo "Publishable ref built without publishing: $IMAGE_NAME:$RELEASE_REF_PUBLISH_TAG"
else
    echo "Build-only branch: not publishing image"
fi
