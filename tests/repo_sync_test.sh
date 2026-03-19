#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="$ROOT_DIR/scripts/repo_sync.sh"
TAGS_SCRIPT_PATH="$ROOT_DIR/scripts/tags_update.sh"
MANIFEST_PATH="$ROOT_DIR/config/php-branches.conf"

assert_contains() {
    local haystack="$1"
    local needle="$2"

    if [[ "$haystack" != *"$needle"* ]]; then
        echo "Expected output to contain: $needle" >&2
        exit 1
    fi
}

[[ -f "$MANIFEST_PATH" ]] || {
    echo "Missing manifest: $MANIFEST_PATH" >&2
    exit 1
}

[[ -x "$SCRIPT_PATH" ]] || {
    echo "Missing executable sync script: $SCRIPT_PATH" >&2
    exit 1
}

[[ -x "$TAGS_SCRIPT_PATH" ]] || {
    echo "Missing executable tags script: $TAGS_SCRIPT_PATH" >&2
    exit 1
}

status_output="$(bash "$SCRIPT_PATH" status)"
assert_contains "$status_output" "Configured PHP branches:"
assert_contains "$status_output" "php85"
assert_contains "$status_output" ".semaphore/semaphore.yml"

dry_run_output="$(bash "$SCRIPT_PATH" bootstrap-version php85)"
assert_contains "$dry_run_output" "Dry run:"
assert_contains "$dry_run_output" "php85"
assert_contains "$dry_run_output" "Dockerfile.ubuntu"

echo "repo_sync_test.sh: PASS"
