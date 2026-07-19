#!/usr/bin/env bash

# Wait until Docker Hub exposes a published version tag, optionally requiring
# the tag metadata to be newer than a provider-supplied event timestamp.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/config/php-branches.conf"

DOCKER_USERNAME="${DOCKER_USERNAME:-$DEFAULT_DOCKER_USERNAME}"
IMAGE_NAME="${IMAGE_NAME:-$DEFAULT_IMAGE_NAME}"
DOCKER_HUB_API_BASE="${DOCKER_HUB_API_BASE:-https://hub.docker.com/v2/repositories}"
CURL_BIN="${CURL_BIN:-curl}"
JQ_BIN="${JQ_BIN:-jq}"
WAIT_FOR_IMAGE=false
POLL_INTERVAL_SECONDS=15
TIMEOUT_SECONDS=1800
UPDATED_AFTER=""
TAG=""

usage() {
    cat <<'EOF'
Usage:
  bash scripts/ci/wait_for_published_image.sh [--wait]
      [--updated-after EPOCH] [--interval SECONDS] [--timeout SECONDS] tag

Checks whether Docker Hub exposes the requested version-like image tag. With
--wait, polls until the tag is ready or the timeout expires. --updated-after
also requires Docker Hub's last_updated timestamp to be newer than the supplied
Unix epoch, preventing a previous image at a reused tag from satisfying a new
publication check.

Exit codes:
  0  the requested published image is ready
  2  the image is pending, missing, stale, or the wait timed out
  3  invalid arguments, configuration, or Docker Hub response

Environment overrides:
  DOCKER_USERNAME       Docker Hub namespace
  IMAGE_NAME            Docker Hub repository
  DOCKER_HUB_API_BASE   Docker Hub repository API root
  CURL_BIN              curl-compatible command
  JQ_BIN                jq-compatible command
EOF
}

die() {
    echo "Error: $*" >&2
    exit 3
}

require_nonnegative_integer() {
    local option_name="$1"
    local value="$2"

    [[ "$value" =~ ^[0-9]+$ ]] \
        || die "$option_name requires a non-negative integer, got: $value"
}

check_published_image() {
    local response
    local record
    local digest
    local updated_epoch

    response="$(
        "$CURL_BIN" -fsSL --retry 2 --retry-connrefused --connect-timeout 15 \
            "$DOCKER_HUB_API_BASE/$DOCKER_USERNAME/$IMAGE_NAME/tags/$TAG"
    )" || return 2

    record="$(
        "$JQ_BIN" -er '
            [
                (.digest | strings | select(length > 0)),
                (.last_updated
                    | strings
                    | sub("\\.[0-9]+Z$"; "Z")
                    | fromdateiso8601)
            ]
            | @tsv
        ' <<<"$response"
    )" || {
        echo "Error: Invalid Docker Hub tag response for $DOCKER_USERNAME/$IMAGE_NAME:$TAG." >&2
        return 3
    }

    IFS=$'\t' read -r digest updated_epoch <<<"$record"
    if [[ -n "$UPDATED_AFTER" && "$updated_epoch" -le "$UPDATED_AFTER" ]]; then
        return 2
    fi

    echo "Published image ready: $DOCKER_USERNAME/$IMAGE_NAME:$TAG ($digest)"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wait)
            WAIT_FOR_IMAGE=true
            ;;
        --updated-after)
            [[ $# -ge 2 ]] || die "--updated-after requires an epoch"
            UPDATED_AFTER="$2"
            require_nonnegative_integer --updated-after "$UPDATED_AFTER"
            shift
            ;;
        --interval)
            [[ $# -ge 2 ]] || die "--interval requires seconds"
            POLL_INTERVAL_SECONDS="$2"
            require_nonnegative_integer --interval "$POLL_INTERVAL_SECONDS"
            shift
            ;;
        --timeout)
            [[ $# -ge 2 ]] || die "--timeout requires seconds"
            TIMEOUT_SECONDS="$2"
            require_nonnegative_integer --timeout "$TIMEOUT_SECONDS"
            shift
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            [[ -z "$TAG" ]] || die "Expected exactly one image tag"
            TAG="$1"
            ;;
    esac
    shift
done

[[ -n "$TAG" ]] || die "Image tag is required"
[[ "$TAG" =~ $PUBLISH_TAG_PATTERN ]] || die "Refusing non-version tag: $TAG"
[[ "$DOCKER_USERNAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
    || die "Unsafe Docker Hub namespace: $DOCKER_USERNAME"
[[ "$IMAGE_NAME" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
    || die "Unsafe Docker Hub repository: $IMAGE_NAME"
command -v "$CURL_BIN" >/dev/null 2>&1 || die "Required command not found: $CURL_BIN"
command -v "$JQ_BIN" >/dev/null 2>&1 || die "Required command not found: $JQ_BIN"

DOCKER_HUB_API_BASE="${DOCKER_HUB_API_BASE%/}"
started_at=$SECONDS

while true; do
    if check_published_image; then
        exit 0
    else
        check_exit=$?
    fi

    [[ $check_exit -ne 3 ]] || exit 3
    if [[ "$WAIT_FOR_IMAGE" != true ]]; then
        echo "Published image is not ready: $DOCKER_USERNAME/$IMAGE_NAME:$TAG" >&2
        exit 2
    fi
    if (( SECONDS - started_at >= TIMEOUT_SECONDS )); then
        echo "Timed out after ${TIMEOUT_SECONDS}s waiting for published image: $DOCKER_USERNAME/$IMAGE_NAME:$TAG" >&2
        exit 2
    fi

    echo "Waiting for published image: $DOCKER_USERNAME/$IMAGE_NAME:$TAG"
    sleep "$POLL_INTERVAL_SECONDS"
done

