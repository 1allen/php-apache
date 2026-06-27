#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="$ROOT_DIR/scripts/repo_sync.sh"
TAGS_SCRIPT_PATH="$ROOT_DIR/scripts/tags_update.sh"
CI_DOCKER_BUILD_SCRIPT_PATH="$ROOT_DIR/scripts/ci/docker_build.sh"
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

    grep -Fq -- "$pattern" "$file_path" || {
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

[[ -x "$CI_DOCKER_BUILD_SCRIPT_PATH" ]] || {
    echo "Missing executable CI Docker build script: $CI_DOCKER_BUILD_SCRIPT_PATH" >&2
    exit 1
}

status_output="$(bash "$SCRIPT_PATH" status)"
assert_contains "$status_output" "Configured PHP branches:"
assert_contains "$status_output" "php85"
assert_contains "$status_output" ".semaphore/semaphore.yml"
assert_contains "$status_output" ".dockerignore"
assert_contains "$status_output" "AGENTS.md"
assert_contains "$status_output" "docs/maintenance.md"
assert_contains "$status_output" "scripts/ci/docker_build.sh"

dry_run_output="$(bash "$SCRIPT_PATH" bootstrap-version php85)"
assert_contains "$dry_run_output" "php85"
assert_contains "$dry_run_output" "Dockerfile.ubuntu"

if [[ "$dry_run_output" != *"Dry run:"* && "$dry_run_output" != *"Local branch already exists: php85"* ]]; then
    echo "Expected bootstrap dry run to report creation or an existing php85 branch." >&2
    exit 1
fi

assert_file_contains "$DOCKERFILE_PATH" 'ARG IMAGICK_VERSION=3.8.1'
assert_file_contains "$DOCKERFILE_PATH" 'ARG IMAGICK_SHA256=3a3587c0a524c17d0dad9673a160b90cd776e836838474e173b549ed864352ee'
assert_file_contains "$DOCKERFILE_PATH" 'ARG IMAGEMAGICK_VERSION=7.1.2-26'
assert_file_contains "$DOCKERFILE_PATH" 'ARG IMAGEMAGICK_SHA256=d63594e334e1c410f600fb9370d78d49e4dc6f315722ca4ba083e864e5c354cb'
assert_file_contains "$DOCKERFILE_PATH" 'ghcr.io/mlocati/php-extension-installer:latest'
assert_file_contains "$DOCKERFILE_PATH" 'curl -fsSL --retry 5 --retry-connrefused --connect-timeout 15'
assert_file_contains "$DOCKERFILE_PATH" 'sha256sum -c -'
assert_file_contains "$DOCKERFILE_PATH" 'PKG_CONFIG_PATH=/usr/local/lib/pkgconfig'
assert_file_contains "$DOCKERFILE_PATH" 'make install DESTDIR=/tmp/imgck'
assert_file_contains "$DOCKERFILE_PATH" "find /tmp/imgck/usr/local/lib -type f"
assert_file_contains "$DOCKERFILE_PATH" 'COPY --chown=$UID:$GID --from=imagemagick-builder /tmp/imgck/usr/local/ /usr/local/'
assert_file_contains "$DOCKERFILE_PATH" 'COPY --from=php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/'
assert_file_contains "$DOCKERFILE_PATH" 'install-php-extensions gmp'
assert_file_contains "$DOCKERFILE_PATH" 'docker-php-ext-configure imagick --with-imagick=/usr/local'
assert_file_contains "$DOCKERFILE_PATH" 'ioncube_ini=/usr/local/etc/php/conf.d/00-ioncube.ini'
assert_file_contains "$DOCKERFILE_PATH" 'ldd "$ioncube_loader"'
assert_file_contains "$DOCKERFILE_PATH" 'groupmod -g "$GID" application'
assert_file_contains "$SEMAPHORE_PATH" 'type: e1-standard-2'
assert_file_contains "$SEMAPHORE_PATH" 'name: build image'
assert_file_contains "$SEMAPHORE_PATH" "tag =~ '^.+$' OR branch =~ '^php[0-9][0-9]$'"
assert_file_contains "$SEMAPHORE_PATH" 'name: publish image'
assert_file_contains "$SEMAPHORE_PATH" 'dependencies:'
assert_file_contains "$SEMAPHORE_PATH" "tag !~ '^.+$' AND branch !~ '^php[0-9][0-9]$'"
assert_file_contains "$SEMAPHORE_PATH" 'DOCKER_BUILDKIT'
assert_file_contains "$SEMAPHORE_PATH" 'CI_GIT_BRANCH="${SEMAPHORE_GIT_BRANCH:-}"'
assert_file_contains "$SEMAPHORE_PATH" 'CI_GIT_TAG="${SEMAPHORE_GIT_TAG_NAME:-}"'
assert_file_contains "$SEMAPHORE_PATH" 'CI_GIT_REF_TYPE="${SEMAPHORE_GIT_REF_TYPE:-}"'
assert_file_contains "$SEMAPHORE_PATH" 'bash scripts/ci/docker_build.sh'
assert_file_contains "$SEMAPHORE_PATH" 'CI_DOCKER_MODE=build'
assert_file_contains "$SEMAPHORE_PATH" 'CI_DOCKER_MODE=build-publish'
assert_file_contains "$SEMAPHORE_PATH" 'dockerhub-1allen'

ruby - "$SEMAPHORE_PATH" <<'RUBY'
require "yaml"

config = YAML.load_file(ARGV.fetch(0))
blocks = config.fetch("blocks")
smoke = blocks.find { |block| block["name"] == "build image" } or abort "Missing build image block"
publish = blocks.find { |block| block["name"] == "publish image" } or abort "Missing publish image block"

abort "Build image block must define empty dependencies" unless smoke.fetch("dependencies") == []
abort "Build image block must not receive secrets" if smoke.fetch("task", {}).key?("secrets")
abort "Publish image block must define empty dependencies" unless publish.fetch("dependencies") == []
unless publish.fetch("task", {}).fetch("secrets", []).any? { |secret| secret["name"] == "dockerhub-1allen" }
    abort "Publish image block must receive dockerhub-1allen secret"
end
RUBY

if grep -q "name: BUILDER_IMAGE" "$SEMAPHORE_PATH"; then
    echo "Expected Semaphore config to let scripts/ci/docker_build.sh own BUILDER_IMAGE." >&2
    exit 1
fi

if grep -q "branch =~ '^php'" "$SEMAPHORE_PATH"; then
    echo "Expected Semaphore config to build phpXX branches." >&2
    exit 1
fi

assert_file_contains "$SCRIPT_PATH" 'commit.gpgsign=false commit'
assert_file_contains "$SCRIPT_PATH" 'worktree prune'
assert_file_contains "$SCRIPT_PATH" 'use_worktree_as_source_branch'
assert_file_contains "$SCRIPT_PATH" 'curl -fsSL --retry 3 --retry-connrefused --connect-timeout 15'
assert_file_contains "$SCRIPT_PATH" 'verify-image-tooling'
assert_file_contains "$SCRIPT_PATH" 'sync-shared [--apply] [branch...]'
assert_file_contains "$SCRIPT_PATH" 'target_branches+=("${SUPPORTED_PHP_BRANCHES[@]}")'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'BUILDKIT_INLINE_CACHE=1'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" '--cache-from "$DOCKER_USERNAME/$IMAGE_NAME:latest"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'CI_GIT_BRANCH="${CI_GIT_BRANCH:-${SEMAPHORE_GIT_BRANCH:-${CIRCLE_BRANCH:-}}}"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'CI_GIT_TAG="${CI_GIT_TAG:-${SEMAPHORE_GIT_TAG_NAME:-${CIRCLE_TAG:-}}}"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'GITHUB_REF_TYPE:-}" == "branch"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'GITHUB_REF_TYPE:-}" == "tag"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'docker build "${build_args[@]}" "$BUILD_CONTEXT"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'CI_DOCKER_MODE="${CI_DOCKER_MODE:-build}"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'CI_GIT_REF_TYPE="${CI_GIT_REF_TYPE:-${SEMAPHORE_GIT_REF_TYPE:-${GITHUB_REF_TYPE:-}}}"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'Non-publish branch push: skipping Docker build'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'build-publish'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'Build-only branch: not publishing image'
assert_file_contains "$TAGS_SCRIPT_PATH" 'target_branches=("${SUPPORTED_PHP_BRANCHES[@]}")'
assert_file_contains "$TAGS_SCRIPT_PATH" 'target_branches+=("$1")'
assert_file_contains "$TAGS_SCRIPT_PATH" 'target_branches=("${SUPPORTED_PHP_BRANCHES[@]}")'
assert_file_contains "$TAGS_SCRIPT_PATH" 'echo "${version:0:1}.${version:1}"'

tooling_output="$(bash "$SCRIPT_PATH" verify-image-tooling latest)"
assert_contains "$tooling_output" "Image tooling branches:"
assert_contains "$tooling_output" "latest: ok"

supported_tooling_output="$(bash "$SCRIPT_PATH" verify-image-tooling || true)"
assert_contains "$supported_tooling_output" "php80"
assert_contains "$supported_tooling_output" "php85"

legacy_tooling_output="$(bash "$SCRIPT_PATH" verify-image-tooling php73 php74 || true)"
assert_contains "$legacy_tooling_output" "php73"
assert_contains "$legacy_tooling_output" "php74"

TMP_DOCKER_BIN="$(mktemp -d "${TMPDIR:-/tmp}/ci-docker-bin.XXXXXX")"
CI_DOCKER_LOG="$TMP_DOCKER_BIN/docker.log"
export CI_DOCKER_LOG

cat > "$TMP_DOCKER_BIN/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$CI_DOCKER_LOG"
case "${1:-}" in
    login)
        cat >/dev/null
        ;;
esac
EOF
chmod +x "$TMP_DOCKER_BIN/docker"

feature_push_ci_output="$(PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_BRANCH=feature/test CI_GIT_REF_TYPE=branch bash "$CI_DOCKER_BUILD_SCRIPT_PATH")"
assert_contains "$feature_push_ci_output" 'Non-publish branch push: skipping Docker build'
if [[ -s "$CI_DOCKER_LOG" ]]; then
    echo "Expected ordinary feature branch push to avoid Docker commands." >&2
    exit 1
fi

build_only_ci_output="$(PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_BRANCH=latest bash "$CI_DOCKER_BUILD_SCRIPT_PATH")"
assert_file_contains "$CI_DOCKER_LOG" 'docker build --pull --build-arg BUILDKIT_INLINE_CACHE=1 --cache-from 1allen/php-apache:latest --cache-from spritsail/debian-builder:latest -f Dockerfile.ubuntu .'
assert_contains "$build_only_ci_output" 'Build-only branch: not publishing image'
if grep -Fq -- '-t php-apache:' "$CI_DOCKER_LOG"; then
    echo "Expected latest build-only CI run to avoid tagging the image." >&2
    exit 1
fi

: > "$CI_DOCKER_LOG"
publishable_build_output="$(PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_BRANCH=php85 bash "$CI_DOCKER_BUILD_SCRIPT_PATH")"
assert_file_contains "$CI_DOCKER_LOG" 'docker build --pull --build-arg BUILDKIT_INLINE_CACHE=1 --cache-from 1allen/php-apache:php85 --cache-from 1allen/php-apache:latest --cache-from spritsail/debian-builder:latest -f Dockerfile.ubuntu -t php-apache:php85 .'
assert_contains "$publishable_build_output" 'Publishable ref built without publishing: php-apache:php85'
if grep -Fq -- 'docker login' "$CI_DOCKER_LOG" || grep -Fq -- 'docker push' "$CI_DOCKER_LOG"; then
    echo "Expected CI build mode to avoid Docker login/push." >&2
    exit 1
fi

: > "$CI_DOCKER_LOG"
PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_BRANCH=php85 CI_DOCKER_MODE=build-publish DOCKER_PASSWORD=test bash "$CI_DOCKER_BUILD_SCRIPT_PATH"
assert_file_contains "$CI_DOCKER_LOG" 'docker build --pull --build-arg BUILDKIT_INLINE_CACHE=1 --cache-from 1allen/php-apache:php85 --cache-from 1allen/php-apache:latest --cache-from spritsail/debian-builder:latest -f Dockerfile.ubuntu -t php-apache:php85 .'
assert_file_contains "$CI_DOCKER_LOG" 'docker login -u 1allen --password-stdin'
assert_file_contains "$CI_DOCKER_LOG" 'docker push 1allen/php-apache:php85'
rm -rf "$TMP_DOCKER_BIN"

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
