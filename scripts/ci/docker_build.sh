#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/php-branches.conf"

DOCKERFILE_PATH="${DOCKERFILE_PATH:-Dockerfile.ubuntu}"
BUILD_CONTEXT="${BUILD_CONTEXT:-.}"
DOCKER_USERNAME="${DOCKER_USERNAME:-$DEFAULT_DOCKER_USERNAME}"
IMAGE_NAME="${IMAGE_NAME:-$DEFAULT_IMAGE_NAME}"
BUILDER_IMAGE="${BUILDER_IMAGE:-$DEFAULT_BUILDER_IMAGE}"
CI_GIT_BRANCH="${CI_GIT_BRANCH:-${SEMAPHORE_GIT_BRANCH:-${CIRCLE_BRANCH:-}}}"
CI_GIT_TAG="${CI_GIT_TAG:-${SEMAPHORE_GIT_TAG_NAME:-${CIRCLE_TAG:-}}}"
CI_GIT_REF_TYPE="${CI_GIT_REF_TYPE:-${SEMAPHORE_GIT_REF_TYPE:-${GITHUB_REF_TYPE:-}}}"
DOCKER_BUILDX_BUILDER="${DOCKER_BUILDX_BUILDER:-php-apache-ci}"
DOCKER_BUILDX_CACHE_DIR="${DOCKER_BUILDX_CACHE_DIR:-}"
DOCKER_BUILDX_CACHE_NEXT_DIR="${DOCKER_BUILDX_CACHE_NEXT_DIR:-}"
export DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-1}"

publish_image=0
publish_tag=""
image_line=""
cache_from_args=()

die() {
    echo "Error: $*" >&2
    exit 1
}

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

derive_image_line() {
    local dockerfile="$ROOT_DIR/$DOCKERFILE_PATH"
    local base_ref
    local base_version

    [[ -f "$dockerfile" ]] || die "Missing Dockerfile: $DOCKERFILE_PATH"

    base_ref="$(
        awk '/^FROM[[:space:]]+webdevops\/php-apache:/ {print $2}' "$dockerfile" \
            | tail -n 1
    )"
    [[ -n "$base_ref" ]] || die "Unable to find webdevops/php-apache base image in $DOCKERFILE_PATH."

    base_version="${base_ref#webdevops/php-apache:}"
    [[ "$base_version" =~ ^([0-9]+)[.]([0-9]+)$ ]] \
        || die "Unsupported webdevops/php-apache base version: $base_version."

    printf 'php%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

resolve_publish_ref() {
    if [[ -n "$CI_GIT_TAG" ]]; then
        if [[ "$CI_GIT_TAG" =~ $PUBLISH_TAG_PATTERN ]]; then
            publish_tag="$CI_GIT_TAG"
            publish_image=1
        elif [[ "${1:-}" == "publish" ]]; then
            die "Refusing to publish non-version tag: $CI_GIT_TAG."
        fi
    elif [[ "$CI_GIT_REF_TYPE" != "pull-request" && "$CI_GIT_BRANCH" =~ ^php[0-9][0-9]$ ]]; then
        publish_tag="$CI_GIT_BRANCH"
        publish_image=1
    fi
}

docker_pull_cache_source() {
    local image_ref="$1"

    docker pull "$image_ref" || true
}

ensure_safe_cache_dir() {
    local cache_dir="$1"

    case "$cache_dir" in
        ""|"/"|".")
            die "Refusing unsafe DOCKER_BUILDX_CACHE_DIR: ${cache_dir:-<empty>}"
            ;;
    esac
}

ensure_buildx_builder() {
    if ! docker buildx inspect "$DOCKER_BUILDX_BUILDER" >/dev/null 2>&1; then
        docker buildx create --name "$DOCKER_BUILDX_BUILDER" --use >/dev/null
    fi

    docker buildx use "$DOCKER_BUILDX_BUILDER" >/dev/null
    docker buildx inspect --bootstrap >/dev/null
}

local_image_ref() {
    [[ "$publish_image" -eq 1 ]] || die "No publishable local image exists for this ref."
    printf '%s:%s\n' "$IMAGE_NAME" "$publish_tag"
}

published_image_ref() {
    [[ "$publish_image" -eq 1 ]] || die "No publishable image exists for this ref."
    printf '%s/%s:%s\n' "$DOCKER_USERNAME" "$IMAGE_NAME" "$publish_tag"
}

artifact_name() {
    [[ "$publish_image" -eq 1 ]] || die "No publishable artifact exists for this ref."
    printf '%s-%s.tar\n' "$IMAGE_NAME" "$publish_tag"
}

metadata_command() {
    printf 'ci_git_branch=%s\n' "$CI_GIT_BRANCH"
    printf 'ci_git_tag=%s\n' "$CI_GIT_TAG"
    printf 'ci_git_ref_type=%s\n' "$CI_GIT_REF_TYPE"
    printf 'image_line=%s\n' "$image_line"
    printf 'registry_cache_ref=%s/%s:%s\n' "$DOCKER_USERNAME" "$IMAGE_NAME" "$image_line"
    printf 'cache_key=docker-buildx-%s\n' "$image_line"
    printf 'publish_image=%s\n' "$publish_image"
    printf 'publish_tag=%s\n' "$publish_tag"

    if [[ "$publish_image" -eq 1 ]]; then
        printf 'local_image_ref=%s\n' "$(local_image_ref)"
        printf 'published_image_ref=%s\n' "$(published_image_ref)"
        printf 'artifact_name=%s\n' "$(artifact_name)"
    fi
}

should_skip_build() {
    [[ "$publish_image" -eq 0 && "$CI_GIT_BRANCH" != "latest" && "$CI_GIT_REF_TYPE" != "pull-request" ]]
}

build_command() {
    cd "$ROOT_DIR"

    if should_skip_build; then
        echo "Non-publish ref: skipping Docker build"
        return
    fi

    docker_pull_cache_source "$DOCKER_USERNAME/$IMAGE_NAME:$image_line"
    docker_pull_cache_source "$BUILDER_IMAGE"
    cache_from_args+=(--cache-from "$DOCKER_USERNAME/$IMAGE_NAME:$image_line")
    cache_from_args+=(--cache-from "$BUILDER_IMAGE")

    local build_args=(
        --pull
        --build-arg BUILDKIT_INLINE_CACHE=1
        "${cache_from_args[@]}"
        -f "$DOCKERFILE_PATH"
    )

    if [[ "$publish_image" -eq 1 ]]; then
        build_args+=(-t "$(local_image_ref)")
    fi

    if [[ -n "$DOCKER_BUILDX_CACHE_DIR" ]]; then
        ensure_safe_cache_dir "$DOCKER_BUILDX_CACHE_DIR"
        DOCKER_BUILDX_CACHE_NEXT_DIR="${DOCKER_BUILDX_CACHE_NEXT_DIR:-${DOCKER_BUILDX_CACHE_DIR}-next}"
        ensure_safe_cache_dir "$DOCKER_BUILDX_CACHE_NEXT_DIR"
        ensure_buildx_builder

        mkdir -p "$(dirname "$DOCKER_BUILDX_CACHE_DIR")"
        rm -rf "$DOCKER_BUILDX_CACHE_NEXT_DIR"

        if [[ -d "$DOCKER_BUILDX_CACHE_DIR" ]]; then
            build_args+=(--cache-from "type=local,src=$DOCKER_BUILDX_CACHE_DIR")
        fi

        build_args+=(--cache-to "type=local,dest=$DOCKER_BUILDX_CACHE_NEXT_DIR,mode=max")
        docker buildx build --load "${build_args[@]}" "$BUILD_CONTEXT"

        if [[ -d "$DOCKER_BUILDX_CACHE_NEXT_DIR" ]]; then
            rm -rf "$DOCKER_BUILDX_CACHE_DIR"
            mv "$DOCKER_BUILDX_CACHE_NEXT_DIR" "$DOCKER_BUILDX_CACHE_DIR"
        fi
    else
        docker build "${build_args[@]}" "$BUILD_CONTEXT"
    fi

    if [[ "$publish_image" -eq 1 ]]; then
        echo "Publishable ref built without publishing: $(local_image_ref)"
    else
        echo "Build-only branch: not publishing image"
    fi
}

save_artifact_command() {
    local artifact_path="${1:-}"

    [[ "$publish_image" -eq 1 ]] || die "Refusing to save image artifact for non-publish ref."
    [[ -n "$artifact_path" ]] || die "Usage: $0 save-artifact <path>"

    mkdir -p "$(dirname "$artifact_path")"
    docker save -o "$artifact_path" "$(local_image_ref)"
}

load_artifact_command() {
    local artifact_path="${1:-}"

    [[ "$publish_image" -eq 1 ]] || die "Refusing to load image artifact for non-publish ref."
    [[ -n "$artifact_path" ]] || die "Usage: $0 load-artifact <path>"
    [[ -f "$artifact_path" ]] || die "Missing image artifact: $artifact_path"

    docker load -i "$artifact_path"
}

publish_command() {
    [[ "$CI_GIT_REF_TYPE" != "pull-request" ]] || die "Refusing to publish from pull-request ref."
    [[ "$publish_image" -eq 1 ]] || die "Refusing to publish non-publish ref."
    [[ -n "${DOCKER_PASSWORD:-}" ]] || die "DOCKER_PASSWORD is required to publish $(published_image_ref)."

    echo "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USERNAME}" --password-stdin
    docker tag "$(local_image_ref)" "$(published_image_ref)"
    docker push "$(published_image_ref)"
}

action="${1:-build}"

image_line="$(derive_image_line)"
resolve_publish_ref "$action"

case "$action" in
    metadata)
        metadata_command
        ;;
    build)
        build_command
        ;;
    save-artifact)
        save_artifact_command "${2:-}"
        ;;
    load-artifact)
        load_artifact_command "${2:-}"
        ;;
    publish)
        publish_command
        ;;
    *)
        die "Unknown Docker build action: $action"
        ;;
esac
