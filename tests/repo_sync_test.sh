#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="$ROOT_DIR/scripts/repo_sync.sh"
TAGS_SCRIPT_PATH="$ROOT_DIR/scripts/tags_update.sh"
MANIFEST_PATH="$ROOT_DIR/config/php-branches.conf"
DOCKERFILE_PATH="$ROOT_DIR/Dockerfile.ubuntu"
SEMAPHORE_PATH="$ROOT_DIR/.semaphore/semaphore.yml"

assert_contains() {
    local haystack="$1"
    local needle="$2"

    if [[ "$haystack" != *"$needle"* ]]; then
        echo "Expected output to contain: $needle" >&2
        exit 1
    fi
}

assert_file_contains() {
    local file_path="$1"
    local pattern="$2"

    grep -q "$pattern" "$file_path" || {
        echo "Expected $file_path to contain: $pattern" >&2
        exit 1
    }
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
assert_contains "$status_output" "AGENTS.md"
assert_contains "$status_output" "docs/maintenance.md"

dry_run_output="$(bash "$SCRIPT_PATH" bootstrap-version php85)"
assert_contains "$dry_run_output" "php85"
assert_contains "$dry_run_output" "Dockerfile.ubuntu"

if [[ "$dry_run_output" != *"Dry run:"* && "$dry_run_output" != *"Local branch already exists: php85"* ]]; then
    echo "Expected bootstrap dry run to report creation or an existing php85 branch." >&2
    exit 1
fi

assert_file_contains "$DOCKERFILE_PATH" 'ARG IMAGICK_VERSION=3.8.1'
assert_file_contains "$DOCKERFILE_PATH" 'ARG IMAGEMAGICK_VERSION=7.1.2-26'
assert_file_contains "$DOCKERFILE_PATH" 'ghcr.io/mlocati/php-extension-installer:latest'
assert_file_contains "$DOCKERFILE_PATH" 'COPY --from=php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/'
assert_file_contains "$DOCKERFILE_PATH" 'install-php-extensions gmp'
assert_file_contains "$SEMAPHORE_PATH" "when: \"branch = 'master'\""

if grep -q "branch =~ '^php'" "$SEMAPHORE_PATH"; then
    echo "Expected Semaphore config to build phpXX branches." >&2
    exit 1
fi

assert_file_contains "$SCRIPT_PATH" 'commit.gpgsign=false commit'
assert_file_contains "$SCRIPT_PATH" 'worktree prune'
assert_file_contains "$SCRIPT_PATH" 'verify-image-tooling'

tooling_output="$(bash "$SCRIPT_PATH" verify-image-tooling latest)"
assert_contains "$tooling_output" "Image tooling branches:"
assert_contains "$tooling_output" "latest: ok"

supported_tooling_output="$(bash "$SCRIPT_PATH" verify-image-tooling)"
assert_contains "$supported_tooling_output" "php80: ok"
assert_contains "$supported_tooling_output" "php85: ok"

legacy_tooling_output="$(bash "$SCRIPT_PATH" verify-image-tooling --legacy || true)"
assert_contains "$legacy_tooling_output" "php73"
assert_contains "$legacy_tooling_output" "php74"

TMP_REPO="$(mktemp -d "${TMPDIR:-/tmp}/repo-sync-test.XXXXXX")"
trap 'rm -rf "$TMP_REPO"' EXIT

mkdir -p "$TMP_REPO/scripts" "$TMP_REPO/config"
cp "$SCRIPT_PATH" "$TMP_REPO/scripts/repo_sync.sh"
cp "$MANIFEST_PATH" "$TMP_REPO/config/php-branches.conf"
cp "$DOCKERFILE_PATH" "$TMP_REPO/Dockerfile.ubuntu"
chmod +x "$TMP_REPO/scripts/repo_sync.sh"

(
    cd "$TMP_REPO"
    git init -b latest >/dev/null 2>&1
    git config user.email "repo-sync-test@example.com"
    git config user.name "Repo Sync Test"
    git add .
    git -c commit.gpgsign=false commit -m "test seed" >/dev/null

    bootstrap_apply_output="$(bash scripts/repo_sync.sh bootstrap-version php85 --apply)"
    assert_contains "$bootstrap_apply_output" "Target branch: php85"
    assert_contains "$bootstrap_apply_output" "Created php85"
    git show-ref --verify --quiet refs/heads/php85
)

echo "repo_sync_test.sh: PASS"
