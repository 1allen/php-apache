#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/php-branches.conf"

DOCKER_USERNAME="${DOCKER_USERNAME:-$DEFAULT_DOCKER_USERNAME}"
IMAGE_NAME="${IMAGE_NAME:-$DEFAULT_IMAGE_NAME}"
DOCKER_HUB_API_BASE="${DOCKER_HUB_API_BASE:-https://hub.docker.com/v2}"
DOCKER_HUB_IDENTIFIER="${DOCKER_HUB_IDENTIFIER:-$DOCKER_USERNAME}"
apply=0

usage() {
    cat <<'EOF'
Usage:
  bash scripts/docker_hub_cleanup.sh [--apply]

Inventories Docker Hub and identifies branch-named tags plus the floating
latest tag. Dry-run by default. Use --apply with DOCKER_HUB_TOKEN set to delete
only those retired tags and verify that none remain.

Environment overrides:
  DOCKER_USERNAME       Docker Hub namespace and authentication identifier
  IMAGE_NAME            Docker Hub repository
  DOCKER_HUB_API_BASE   Docker Hub API root
  DOCKER_HUB_IDENTIFIER Authentication identifier when different from namespace
  DOCKER_HUB_TOKEN      Docker Hub PAT/OAT secret required by --apply
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

tag_in_list() {
    local needle="$1"
    shift
    local item

    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done

    return 1
}

fetch_inventory() {
    local url="$DOCKER_HUB_API_BASE/namespaces/$DOCKER_USERNAME/repositories/$IMAGE_NAME/tags?page_size=100"
    local response
    local next_url

    while [[ -n "$url" ]]; do
        response="$(curl -fsSL --retry 3 --retry-connrefused --connect-timeout 15 "$url")" \
            || die "Unable to read Docker Hub tags for $DOCKER_USERNAME/$IMAGE_NAME."
        jq -er '.results[]? | [.name, .digest, .last_updated] | @tsv' <<<"$response" \
            || die "Invalid Docker Hub tag inventory for $DOCKER_USERNAME/$IMAGE_NAME."
        next_url="$(jq -er '.next // ""' <<<"$response")" \
            || die "Invalid Docker Hub pagination metadata for $DOCKER_USERNAME/$IMAGE_NAME."
        url="$next_url"
    done
}

print_rows() {
    local title="$1"
    shift
    local row

    echo "$title"
    if [[ $# -eq 0 ]]; then
        echo "  (none)"
        return
    fi

    for row in "$@"; do
        printf '  - %s\n' "${row//$'\t'/  }"
    done
}

classify_inventory() {
    local inventory="$1"
    local name
    local digest
    local updated

    present_retired_rows=()
    version_rows=()
    other_rows=()

    while IFS=$'\t' read -r name digest updated; do
        [[ -n "$name" ]] || continue
        if tag_in_list "$name" "${retired_tags[@]}"; then
            present_retired_rows+=("$name"$'\t'"$digest"$'\t'"$updated")
        elif [[ "$name" =~ $PUBLISH_TAG_PATTERN ]]; then
            version_rows+=("$name"$'\t'"$digest"$'\t'"$updated")
        else
            other_rows+=("$name"$'\t'"$digest"$'\t'"$updated")
        fi
    done <<<"$inventory"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)
            apply=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
    shift
done

require_command curl
require_command jq

DOCKER_HUB_API_BASE="${DOCKER_HUB_API_BASE%/}"
[[ "$DOCKER_USERNAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "Unsafe Docker Hub namespace: $DOCKER_USERNAME"
[[ "$IMAGE_NAME" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "Unsafe Docker Hub repository: $IMAGE_NAME"

retired_tags=(latest "${LEGACY_PHP_BRANCHES[@]}" "${SUPPORTED_PHP_BRANCHES[@]}")
for retired_tag in "${retired_tags[@]}"; do
    [[ "$retired_tag" == latest || "$retired_tag" =~ $PHP_BRANCH_PATTERN ]] \
        || die "Unsafe retired Docker Hub tag: $retired_tag"
    [[ ! "$retired_tag" =~ $PUBLISH_TAG_PATTERN ]] \
        || die "Refusing to classify version-like tag as retired: $retired_tag"
done

inventory="$(fetch_inventory)"
classify_inventory "$inventory"

echo "Docker Hub repository: $DOCKER_USERNAME/$IMAGE_NAME"
print_rows "Retired Docker Hub tags present:" "${present_retired_rows[@]+"${present_retired_rows[@]}"}"
print_rows "Preserved version-like tags:" "${version_rows[@]+"${version_rows[@]}"}"
print_rows "Other untouched tags:" "${other_rows[@]+"${other_rows[@]}"}"

if [[ $apply -eq 0 ]]; then
    echo "Dry run: no Docker Hub tags were deleted."
    exit 0
fi

if [[ ${#present_retired_rows[@]} -eq 0 ]]; then
    echo "Docker Hub cleanup verified: no retired tags remain."
    exit 0
fi

[[ -n "${DOCKER_HUB_TOKEN:-}" ]] || die "DOCKER_HUB_TOKEN is required with --apply."

auth_payload="$(jq -nc \
    --arg identifier "$DOCKER_HUB_IDENTIFIER" \
    --arg secret "$DOCKER_HUB_TOKEN" \
    '{identifier: $identifier, secret: $secret}')"
auth_response="$(curl -fsSL -X POST \
    -H 'Content-Type: application/json' \
    --data-binary @- \
    "$DOCKER_HUB_API_BASE/auth/token" <<<"$auth_payload")" \
    || die "Docker Hub authentication failed."
access_token="$(jq -er '.access_token | strings | select(length > 0)' <<<"$auth_response")" \
    || die "Docker Hub authentication response did not contain an access token."
[[ "$access_token" =~ ^[A-Za-z0-9._~-]+$ ]] \
    || die "Docker Hub authentication response contained an unsafe access token."
unset DOCKER_HUB_TOKEN auth_payload auth_response

for row in "${present_retired_rows[@]}"; do
    retired_tag="${row%%$'\t'*}"
    curl -fsS -X DELETE \
        --config - \
        "$DOCKER_HUB_API_BASE/namespaces/$DOCKER_USERNAME/repositories/$IMAGE_NAME/tags/$retired_tag" \
        >/dev/null \
        <<<"header = \"Authorization: Bearer $access_token\"" \
        || die "Failed to delete Docker Hub tag: $DOCKER_USERNAME/$IMAGE_NAME:$retired_tag"
    echo "Deleted Docker Hub tag: $DOCKER_USERNAME/$IMAGE_NAME:$retired_tag"
done

inventory="$(fetch_inventory)"
classify_inventory "$inventory"
if [[ ${#present_retired_rows[@]} -ne 0 ]]; then
    print_rows "Retired Docker Hub tags still present:" "${present_retired_rows[@]}"
    die "Docker Hub cleanup verification failed."
fi

echo "Docker Hub cleanup verified: no retired tags remain."
