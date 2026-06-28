#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/php-branches.conf"

DOCKER_USERNAME="${DOCKER_USERNAME:-$DEFAULT_DOCKER_USERNAME}"
IMAGE_NAME="${IMAGE_NAME:-$DEFAULT_IMAGE_NAME}"
TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:latest}"
CI_GIT_BRANCH="${CI_GIT_BRANCH:-${SEMAPHORE_GIT_BRANCH:-${CIRCLE_BRANCH:-}}}"
CI_GIT_TAG="${CI_GIT_TAG:-${SEMAPHORE_GIT_TAG_NAME:-${CIRCLE_TAG:-}}}"
CI_GIT_REF_TYPE="${CI_GIT_REF_TYPE:-${SEMAPHORE_GIT_REF_TYPE:-${GITHUB_REF_TYPE:-}}}"

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

if [[ "$CI_GIT_REF_TYPE" == "pull-request" ]]; then
    die "Refusing to scan pull-request ref."
fi

publish_tag=""
if [[ -n "$CI_GIT_TAG" ]]; then
    [[ "$CI_GIT_TAG" =~ $PUBLISH_TAG_PATTERN ]] || die "Refusing to scan non-version tag: $CI_GIT_TAG."
    publish_tag="$CI_GIT_TAG"
elif [[ "$CI_GIT_BRANCH" =~ ^php[0-9][0-9]$ ]]; then
    publish_tag="$CI_GIT_BRANCH"
else
    die "Refusing to scan non-publish branch: ${CI_GIT_BRANCH:-<unset>}."
fi

image_ref="$DOCKER_USERNAME/$IMAGE_NAME:$publish_tag"
echo "Running non-blocking Trivy scan for $image_ref"
if ! docker run --rm "$TRIVY_IMAGE" image --exit-code 0 --severity HIGH,CRITICAL "$image_ref"; then
    echo "Warning: non-blocking Trivy scan failed for $image_ref" >&2
fi
