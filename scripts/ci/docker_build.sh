#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/php-branches.conf"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/release_ref.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/image_contract.sh"

DOCKERFILE_PATH="${DOCKERFILE_PATH:-Dockerfile.ubuntu}"
BUILD_CONTEXT="${BUILD_CONTEXT:-.}"
DOCKER_USERNAME="${DOCKER_USERNAME:-$DEFAULT_DOCKER_USERNAME}"
IMAGE_NAME="${IMAGE_NAME:-$DEFAULT_IMAGE_NAME}"
BUILDER_IMAGE="${BUILDER_IMAGE:-$DEFAULT_BUILDER_IMAGE}"
CI_DOCKER_MODE="${CI_DOCKER_MODE:-build}"
export DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-1}"
cache_from_args=()
cache_source_refs=()

die() {
    echo "Error: $*" >&2
    exit 1
}

docker_pull_cache_source() {
    local image_ref="$1"

    docker pull "$image_ref" || true
}

add_cache_source() {
    local image_ref="$1"
    local existing

    for existing in "${cache_source_refs[@]+"${cache_source_refs[@]}"}"; do
        [[ "$existing" == "$image_ref" ]] && return 0
    done

    docker_pull_cache_source "$image_ref"
    cache_source_refs+=("$image_ref")
    cache_from_args+=(--cache-from "$image_ref")
}

write_build_metrics() {
    local output_path="$1"
    local tag="$2"
    local cache_prepare_seconds="$3"
    local build_seconds="$4"
    local publish_seconds="$5"
    local total_seconds="$6"
    local cache_sources
    local output_dir

    if [[ "$output_path" == */* ]]; then
        output_dir="${output_path%/*}"
        [[ -d "$output_dir" ]] || die "Build metrics directory does not exist: $output_dir"
    fi

    cache_sources="$(IFS=,; printf '%s' "${cache_source_refs[*]}")"
    {
        printf 'tag\tcache_prepare_seconds\tbuild_seconds\tpublish_seconds\ttotal_seconds\tcache_sources\n'
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$tag" "$cache_prepare_seconds" "$build_seconds" \
            "$publish_seconds" "$total_seconds" "$cache_sources"
    } >"$output_path"
}

case "$CI_DOCKER_MODE" in
    build|build-publish|preflight)
        ;;
    *)
        die "Unknown CI_DOCKER_MODE: $CI_DOCKER_MODE"
        ;;
esac

release_ref_resolve

cd "$ROOT_DIR"

if [[ "$CI_DOCKER_MODE" == "preflight" ]]; then
    if [[ -n "$RELEASE_REF_TAG" && -z "$RELEASE_REF_PUBLISH_TAG" ]]; then
        die "Refusing preflight for non-version tag: $RELEASE_REF_TAG."
    fi
    if [[ -z "$RELEASE_REF_TAG" && ! "$RELEASE_REF_BRANCH" =~ $PHP_BRANCH_PATTERN ]]; then
        die "Refusing preflight for non-release branch: ${RELEASE_REF_BRANCH:-<unset>}."
    fi

    dockerfile_content="$(<"$DOCKERFILE_PATH")"
    missing_invariants="$(image_contract_missing_invariants "$dockerfile_content" || true)"
    [[ -z "$missing_invariants" ]] || die "Release source violates image contract:${missing_invariants//$'\n'/$'\n  - '}"
    echo "Release source preflight passed: ${RELEASE_REF_TAG:-$RELEASE_REF_BRANCH}"
    exit 0
fi

if [[ "$CI_DOCKER_MODE" == "build-publish" && "$RELEASE_REF_TYPE" == "pull-request" ]]; then
    die "Refusing to publish from pull-request ref."
fi

if [[ -n "$RELEASE_REF_TAG" && -z "$RELEASE_REF_PUBLISH_TAG" && "$CI_DOCKER_MODE" == "build-publish" ]]; then
    die "Refusing to publish non-version tag: $RELEASE_REF_TAG."
fi

if [[ "$CI_DOCKER_MODE" == "build-publish" ]] && ! release_ref_is_publishable; then
    die "Refusing to publish from non-version ref: ${RELEASE_REF_TAG:-${RELEASE_REF_BRANCH:-<unset>}}."
fi

if ! release_ref_requires_build; then
    echo "Non-build ref: skipping Docker build"
    exit 0
fi

script_started_seconds=$SECONDS
cache_started_seconds=$SECONDS

if release_ref_is_publishable; then
    add_cache_source "$DOCKER_USERNAME/$IMAGE_NAME:$RELEASE_REF_PUBLISH_TAG"
    minor_cache_tag="$(release_ref_version_to_minor "$RELEASE_REF_PUBLISH_TAG")"
    if [[ "$minor_cache_tag" != "$RELEASE_REF_PUBLISH_TAG" ]]; then
        add_cache_source "$DOCKER_USERNAME/$IMAGE_NAME:$minor_cache_tag"
    fi
elif [[ "$RELEASE_REF_TYPE" == "pull-request" && "$RELEASE_REF_BRANCH" =~ $PHP_BRANCH_PATTERN ]]; then
    add_cache_source "$DOCKER_USERNAME/$IMAGE_NAME:$(release_ref_branch_to_version "$RELEASE_REF_BRANCH")"
else
    add_cache_source "$DOCKER_USERNAME/$IMAGE_NAME:$DEFAULT_BUILD_CACHE_TAG"
fi

add_cache_source "$BUILDER_IMAGE"
cache_prepare_seconds=$((SECONDS - cache_started_seconds))

build_args=(
    --pull
    --build-arg BUILDKIT_INLINE_CACHE=1
    "${cache_from_args[@]}"
    -f "$DOCKERFILE_PATH"
)

if release_ref_is_publishable; then
    build_args+=(-t "$IMAGE_NAME:$RELEASE_REF_PUBLISH_TAG")
fi

build_started_seconds=$SECONDS
docker build "${build_args[@]}" "$BUILD_CONTEXT"
build_seconds=$((SECONDS - build_started_seconds))
echo "Docker build completed in ${build_seconds}s"

if release_ref_is_publishable && [[ "$CI_DOCKER_MODE" == "build-publish" ]]; then
    [[ -n "${DOCKER_PASSWORD:-}" ]] || die "DOCKER_PASSWORD is required to publish $DOCKER_USERNAME/$IMAGE_NAME:$RELEASE_REF_PUBLISH_TAG."
    publish_started_seconds=$SECONDS
    echo "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USERNAME}" --password-stdin
    docker tag "$IMAGE_NAME:$RELEASE_REF_PUBLISH_TAG" "$DOCKER_USERNAME/$IMAGE_NAME:$RELEASE_REF_PUBLISH_TAG"
    docker push "$DOCKER_USERNAME/$IMAGE_NAME:$RELEASE_REF_PUBLISH_TAG"
    publish_seconds=$((SECONDS - publish_started_seconds))
    total_seconds=$((SECONDS - script_started_seconds))
    if [[ -n "${CI_BUILD_METRICS_FILE:-}" ]]; then
        write_build_metrics "$CI_BUILD_METRICS_FILE" "$RELEASE_REF_PUBLISH_TAG" \
            "$cache_prepare_seconds" "$build_seconds" "$publish_seconds" "$total_seconds"
        echo "Build metrics written to $CI_BUILD_METRICS_FILE"
    fi
elif release_ref_is_publishable; then
    echo "Publishable ref built without publishing: $IMAGE_NAME:$RELEASE_REF_PUBLISH_TAG"
else
    echo "Build-only branch: not publishing image"
fi
