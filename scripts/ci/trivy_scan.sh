#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/php-branches.conf"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/release_ref.sh"

DOCKER_USERNAME="${DOCKER_USERNAME:-$DEFAULT_DOCKER_USERNAME}"
IMAGE_NAME="${IMAGE_NAME:-$DEFAULT_IMAGE_NAME}"
TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:latest}"

die() {
    echo "Error: $*" >&2
    exit 1
}

release_ref_resolve

if [[ "$RELEASE_REF_TYPE" == "pull-request" ]]; then
    die "Refusing to scan pull-request ref."
fi

if [[ -n "$RELEASE_REF_TAG" && -z "$RELEASE_REF_PUBLISH_TAG" ]]; then
    die "Refusing to scan non-version tag: $RELEASE_REF_TAG."
fi

release_ref_is_publishable || die "Refusing to scan non-publish branch: ${RELEASE_REF_BRANCH:-<unset>}."

image_ref="$DOCKER_USERNAME/$IMAGE_NAME:$RELEASE_REF_PUBLISH_TAG"
echo "Running non-blocking Trivy scan for $image_ref"
if ! docker run --rm "$TRIVY_IMAGE" image --exit-code 0 --severity HIGH,CRITICAL "$image_ref"; then
    echo "Warning: non-blocking Trivy scan failed for $image_ref" >&2
fi
