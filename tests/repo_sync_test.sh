#!/usr/bin/env bash
# shellcheck disable=SC2016

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="$ROOT_DIR/scripts/repo_sync.sh"
TAGS_SCRIPT_PATH="$ROOT_DIR/scripts/tags_update.sh"
CI_DOCKER_BUILD_SCRIPT_PATH="$ROOT_DIR/scripts/ci/docker_build.sh"
CI_TRIVY_SCAN_SCRIPT_PATH="$ROOT_DIR/scripts/ci/trivy_scan.sh"
MANIFEST_PATH="$ROOT_DIR/config/php-branches.conf"
DOCKERFILE_PATH="$ROOT_DIR/Dockerfile.ubuntu"
SEMAPHORE_PATH="$ROOT_DIR/.semaphore/semaphore.yml"
SEMAPHORE_PUBLISH_PATH="$ROOT_DIR/.semaphore/publish.yml"

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

assert_file_not_contains() {
    local file_path="$1"
    local pattern="$2"

    if grep -Fq -- "$pattern" "$file_path"; then
        echo "Expected $file_path not to contain: $pattern" >&2
        exit 1
    fi
}

[[ -f "$MANIFEST_PATH" ]] || {
    echo "Missing manifest: $MANIFEST_PATH" >&2
    exit 1
}

# shellcheck disable=SC1090
source "$MANIFEST_PATH"

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

[[ -x "$CI_TRIVY_SCAN_SCRIPT_PATH" ]] || {
    echo "Missing executable CI Trivy scan script: $CI_TRIVY_SCAN_SCRIPT_PATH" >&2
    exit 1
}

status_output="$(bash "$SCRIPT_PATH" status)"
assert_contains "$status_output" "Configured PHP branches:"
assert_contains "$status_output" "php85"
assert_contains "$status_output" ".semaphore/semaphore.yml"
assert_contains "$status_output" ".semaphore/publish.yml"
assert_contains "$status_output" ".dockerignore"
assert_contains "$status_output" "AGENTS.md"
assert_contains "$status_output" "docs/maintenance.md"
assert_contains "$status_output" "scripts/ci/docker_build.sh"
assert_contains "$status_output" "scripts/ci/trivy_scan.sh"

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
[[ -n "$PHP_EXTENSION_INSTALLER_IMAGE" ]] || {
    echo "Expected PHP_EXTENSION_INSTALLER_IMAGE to be configured." >&2
    exit 1
}

[[ -n "$PUBLISH_TAG_PATTERN" ]] || {
    echo "Expected PUBLISH_TAG_PATTERN to be configured." >&2
    exit 1
}

[[ -n "$DEFAULT_DOCKER_USERNAME" && -n "$DEFAULT_IMAGE_NAME" && -n "$DEFAULT_BUILDER_IMAGE" ]] || {
    echo "Expected default Docker image refs to be configured." >&2
    exit 1
}

if grep -Eq '^(SEMAPHORE_MACHINE_TYPE|SEMAPHORE_OS_IMAGE)=' "$MANIFEST_PATH"; then
    echo "Expected Semaphore adapter settings to stay in .semaphore/semaphore.yml, not config/php-branches.conf." >&2
    exit 1
fi

assert_file_contains "$DOCKERFILE_PATH" "ARG PHP_EXTENSION_INSTALLER_IMAGE=$PHP_EXTENSION_INSTALLER_IMAGE"
assert_file_contains "$DOCKERFILE_PATH" 'FROM ${PHP_EXTENSION_INSTALLER_IMAGE} AS php-extension-installer'
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
assert_file_contains "$SEMAPHORE_PATH" 'os_image: ubuntu2404'
assert_file_contains "$SEMAPHORE_PATH" 'global_job_config:'
assert_file_contains "$SEMAPHORE_PATH" 'prologue:'
assert_file_contains "$SEMAPHORE_PATH" 'checkout'
assert_file_contains "$SEMAPHORE_PATH" 'name: build image'
assert_file_contains "$SEMAPHORE_PATH" "pull_request =~ '^.+$' OR branch = 'latest' OR branch =~ '^php[0-9][0-9]$' OR tag =~ '$PUBLISH_TAG_PATTERN'"
assert_file_contains "$SEMAPHORE_PATH" 'CI_GIT_BRANCH="${SEMAPHORE_GIT_BRANCH:-}"'
assert_file_contains "$SEMAPHORE_PATH" 'CI_GIT_TAG="${SEMAPHORE_GIT_TAG_NAME:-}"'
assert_file_contains "$SEMAPHORE_PATH" 'CI_GIT_REF_TYPE="${SEMAPHORE_GIT_REF_TYPE:-}"'
assert_file_contains "$SEMAPHORE_PATH" 'bash scripts/ci/docker_build.sh'
assert_file_contains "$SEMAPHORE_PATH" 'export DOCKER_BUILDX_CACHE_DIR=.cache/docker-buildx'
assert_file_contains "$SEMAPHORE_PATH" 'cache_ref="${cache_ref//[^A-Za-z0-9_.-]/-}"'
assert_file_contains "$SEMAPHORE_PATH" 'cache restore "docker-buildx-${cache_ref},docker-buildx-latest" || true'
assert_file_contains "$SEMAPHORE_PATH" 'cache store "docker-buildx-${cache_ref},docker-buildx-latest" "$DOCKER_BUILDX_CACHE_DIR" || true'
assert_file_contains "$SEMAPHORE_PATH" 'name: CI_DOCKER_MODE'
assert_file_contains "$SEMAPHORE_PATH" 'value: build'
assert_file_contains "$SEMAPHORE_PATH" 'promotions:'
assert_file_contains "$SEMAPHORE_PATH" 'name: publish final image'
assert_file_contains "$SEMAPHORE_PATH" 'pipeline_file: publish.yml'
assert_file_contains "$SEMAPHORE_PATH" "result = 'passed' AND pull_request !~ '^.+$' AND (branch =~ '^php[0-9][0-9]$' OR tag =~ '$PUBLISH_TAG_PATTERN')"
assert_file_not_contains "$SEMAPHORE_PATH" '*run_docker_ci'
assert_file_not_contains "$SEMAPHORE_PATH" '&run_docker_ci'

assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'name: php-apache publish pipeline'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'name: publish image'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'name: scan published image'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'dependencies:'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" '- publish image'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'bash scripts/ci/docker_build.sh'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'bash scripts/ci/trivy_scan.sh'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'export DOCKER_BUILDX_CACHE_DIR=.cache/docker-buildx'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'cache restore "docker-buildx-${cache_ref},docker-buildx-latest" || true'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'cache store "docker-buildx-${cache_ref},docker-buildx-latest" "$DOCKER_BUILDX_CACHE_DIR" || true'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'name: CI_DOCKER_MODE'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'value: build-publish'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'dockerhub-1allen'
assert_file_not_contains "$SEMAPHORE_PUBLISH_PATH" '*run_docker_ci'
assert_file_not_contains "$SEMAPHORE_PUBLISH_PATH" '&run_docker_ci'

ruby - "$SEMAPHORE_PATH" "$SEMAPHORE_PUBLISH_PATH" <<'RUBY'
require "yaml"

build_config = YAML.load_file(ARGV.fetch(0))
publish_config = YAML.load_file(ARGV.fetch(1))
build_blocks = build_config.fetch("blocks")
publish_blocks = publish_config.fetch("blocks")
smoke = build_blocks.find { |block| block["name"] == "build image" } or abort "Missing build image block"
publish = publish_blocks.find { |block| block["name"] == "publish image" } or abort "Missing publish image block"
scan = publish_blocks.find { |block| block["name"] == "scan published image" } or abort "Missing scan published image block"

abort "Root pipeline must have one visible block" unless build_blocks.size == 1
abort "Global prologue must run checkout" unless build_config.fetch("global_job_config").fetch("prologue").fetch("commands") == ["checkout"]
abort "Build image block should not define empty dependencies" if smoke.key?("dependencies")
abort "Build image block must run for PRs, latest, and publishable refs" unless smoke.fetch("run").fetch("when") == "pull_request =~ '^.+$' OR branch = 'latest' OR branch =~ '^php[0-9][0-9]$' OR tag =~ '^[0-9]+[.][0-9]+([.][0-9]+)?$'"
abort "Build image block must not receive secrets" if smoke.fetch("task", {}).key?("secrets")
abort "Build image block must set build mode" unless smoke.fetch("task").fetch("env_vars").any? { |env| env["name"] == "CI_DOCKER_MODE" && env["value"] == "build" }
promotion = build_config.fetch("promotions").find { |item| item["name"] == "publish final image" } or abort "Missing publish final image promotion"
abort "Publish promotion must target publish.yml" unless promotion["pipeline_file"] == "publish.yml"
unless promotion.fetch("auto_promote").fetch("when") == "result = 'passed' AND pull_request !~ '^.+$' AND (branch =~ '^php[0-9][0-9]$' OR tag =~ '^[0-9]+[.][0-9]+([.][0-9]+)?$')"
    abort "Publish promotion must only run after passed publishable refs"
end
abort "Publish image block must explicitly define no dependencies" unless publish.fetch("dependencies") == []
abort "Publish image block must set publish mode" unless publish.fetch("task").fetch("env_vars").any? { |env| env["name"] == "CI_DOCKER_MODE" && env["value"] == "build-publish" }
unless publish.fetch("task", {}).fetch("secrets", []).any? { |secret| secret["name"] == "dockerhub-1allen" }
    abort "Publish image block must receive dockerhub-1allen secret"
end
abort "Scan block must depend on publish image" unless scan.fetch("dependencies") == ["publish image"]
abort "Scan block must not receive secrets" if scan.fetch("task", {}).key?("secrets")
RUBY

if grep -Eq "name: (BUILDER_IMAGE|DOCKER_USERNAME|IMAGE_NAME|DOCKER_BUILDKIT)" "$SEMAPHORE_PATH"; then
    echo "Expected Semaphore config to let scripts/ci/docker_build.sh own provider-neutral Docker defaults." >&2
    exit 1
fi

assert_file_contains "$SCRIPT_PATH" 'commit.gpgsign=false commit'
assert_file_contains "$SCRIPT_PATH" 'worktree prune'
assert_file_contains "$SCRIPT_PATH" 'use_worktree_as_source_branch'
assert_file_contains "$SCRIPT_PATH" 'curl -fsSL --retry 3 --retry-connrefused --connect-timeout 15'
assert_file_contains "$SCRIPT_PATH" 'verify-image-tooling'
assert_file_contains "$SCRIPT_PATH" 'sync-shared [--apply] [branch...]'
assert_file_contains "$SCRIPT_PATH" 'target_branches+=("${SUPPORTED_PHP_BRANCHES[@]}")'
assert_file_contains "$SCRIPT_PATH" 'php_extension_installer_source_present'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'BUILDKIT_INLINE_CACHE=1'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'DOCKER_BUILDX_CACHE_DIR="${DOCKER_BUILDX_CACHE_DIR:-}"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'docker buildx build --load "${build_args[@]}" "$BUILD_CONTEXT"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" '--cache-from "type=local,src=$DOCKER_BUILDX_CACHE_DIR"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" '--cache-to "type=local,dest=$DOCKER_BUILDX_CACHE_NEXT_DIR,mode=max"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'export DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-1}"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'DOCKER_USERNAME="${DOCKER_USERNAME:-$DEFAULT_DOCKER_USERNAME}"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'IMAGE_NAME="${IMAGE_NAME:-$DEFAULT_IMAGE_NAME}"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'BUILDER_IMAGE="${BUILDER_IMAGE:-$DEFAULT_BUILDER_IMAGE}"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" '--cache-from "$DOCKER_USERNAME/$IMAGE_NAME:latest"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'source "$ROOT_DIR/config/php-branches.conf"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'CI_GIT_BRANCH="${CI_GIT_BRANCH:-${SEMAPHORE_GIT_BRANCH:-${CIRCLE_BRANCH:-}}}"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'CI_GIT_TAG="${CI_GIT_TAG:-${SEMAPHORE_GIT_TAG_NAME:-${CIRCLE_TAG:-}}}"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'GITHUB_REF_TYPE:-}" == "branch"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'GITHUB_REF_TYPE:-}" == "tag"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'docker build "${build_args[@]}" "$BUILD_CONTEXT"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'CI_DOCKER_MODE="${CI_DOCKER_MODE:-build}"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'CI_GIT_REF_TYPE="${CI_GIT_REF_TYPE:-${SEMAPHORE_GIT_REF_TYPE:-${GITHUB_REF_TYPE:-}}}"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'Refusing to publish from pull-request ref.'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'Refusing to publish non-version tag'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'Non-publish ref: skipping Docker build'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'build-publish'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'Build-only branch: not publishing image'
assert_file_not_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'trivy'
assert_file_contains "$CI_TRIVY_SCAN_SCRIPT_PATH" 'TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:latest}"'
assert_file_contains "$CI_TRIVY_SCAN_SCRIPT_PATH" 'docker run --rm "$TRIVY_IMAGE" image --exit-code 0 --severity HIGH,CRITICAL "$image_ref"'
assert_file_contains "$CI_TRIVY_SCAN_SCRIPT_PATH" 'Warning: non-blocking Trivy scan failed for $image_ref'
assert_file_contains "$CI_TRIVY_SCAN_SCRIPT_PATH" 'Refusing to scan pull-request ref.'
assert_file_contains "$CI_TRIVY_SCAN_SCRIPT_PATH" 'Refusing to scan non-version tag'
assert_file_contains "$CI_TRIVY_SCAN_SCRIPT_PATH" 'Refusing to scan non-publish branch'
assert_file_contains "$TAGS_SCRIPT_PATH" 'target_branches=("${SUPPORTED_PHP_BRANCHES[@]}")'
assert_file_contains "$TAGS_SCRIPT_PATH" 'target_branches+=("$1")'
assert_file_contains "$TAGS_SCRIPT_PATH" 'target_branches=("${SUPPORTED_PHP_BRANCHES[@]}")'
assert_file_contains "$TAGS_SCRIPT_PATH" 'echo "${version:0:1}.${version:1}"'

tooling_output="$(bash "$SCRIPT_PATH" verify-image-tooling latest)"
assert_contains "$tooling_output" "Image tooling branches:"
assert_contains "$tooling_output" "latest: ok"

supported_tooling_output="$(bash "$SCRIPT_PATH" verify-image-tooling)"
assert_contains "$supported_tooling_output" "php80"
assert_contains "$supported_tooling_output" "php85"
assert_contains "$supported_tooling_output" "php80: ok"
assert_contains "$supported_tooling_output" "php85: ok"

legacy_tooling_output="$(bash "$SCRIPT_PATH" verify-image-tooling php73 php74 || true)"
assert_contains "$legacy_tooling_output" "php73"
assert_contains "$legacy_tooling_output" "php74"

TMP_DOCKER_BIN="$(mktemp -d "${TMPDIR:-/tmp}/ci-docker-bin.XXXXXX")"
CI_DOCKER_LOG="$TMP_DOCKER_BIN/docker.log"
PR_PUBLISH_OUTPUT="$TMP_DOCKER_BIN/pr-publish.out"
TAG_PUBLISH_OUTPUT="$TMP_DOCKER_BIN/tag-publish.out"
export CI_DOCKER_LOG

default_image_ref="$DEFAULT_DOCKER_USERNAME/$DEFAULT_IMAGE_NAME"

cat > "$TMP_DOCKER_BIN/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$CI_DOCKER_LOG"
if [[ "${1:-}" == "run" && "$*" == *"failing-trivy"* ]]; then
    exit 42
fi
case "${1:-}" in
    login)
        cat >/dev/null
        ;;
esac
EOF
chmod +x "$TMP_DOCKER_BIN/docker"

feature_push_ci_output="$(PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_BRANCH=feature/test CI_GIT_REF_TYPE=branch bash "$CI_DOCKER_BUILD_SCRIPT_PATH")"
assert_contains "$feature_push_ci_output" 'Non-publish ref: skipping Docker build'
if [[ -s "$CI_DOCKER_LOG" ]]; then
    echo "Expected ordinary feature branch push to avoid Docker commands." >&2
    exit 1
fi

build_only_ci_output="$(PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_BRANCH=latest bash "$CI_DOCKER_BUILD_SCRIPT_PATH")"
assert_file_contains "$CI_DOCKER_LOG" "docker build --pull --build-arg BUILDKIT_INLINE_CACHE=1 --cache-from $default_image_ref:latest --cache-from $DEFAULT_BUILDER_IMAGE -f Dockerfile.ubuntu ."
assert_contains "$build_only_ci_output" 'Build-only branch: not publishing image'
if grep -Fq -- "-t $DEFAULT_IMAGE_NAME:" "$CI_DOCKER_LOG"; then
    echo "Expected latest build-only CI run to avoid tagging the image." >&2
    exit 1
fi

: > "$CI_DOCKER_LOG"
mkdir -p "$TMP_DOCKER_BIN/buildx-cache"
buildx_cache_output="$(PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_BRANCH=latest DOCKER_BUILDX_CACHE_DIR="$TMP_DOCKER_BIN/buildx-cache" bash "$CI_DOCKER_BUILD_SCRIPT_PATH")"
assert_file_contains "$CI_DOCKER_LOG" "docker buildx build --load --pull --build-arg BUILDKIT_INLINE_CACHE=1 --cache-from $default_image_ref:latest --cache-from $DEFAULT_BUILDER_IMAGE -f Dockerfile.ubuntu --cache-from type=local,src=$TMP_DOCKER_BIN/buildx-cache --cache-to type=local,dest=$TMP_DOCKER_BIN/buildx-cache-next,mode=max ."
assert_contains "$buildx_cache_output" 'Build-only branch: not publishing image'

: > "$CI_DOCKER_LOG"
pr_target_branch_output="$(PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_BRANCH=php85 CI_GIT_REF_TYPE=pull-request bash "$CI_DOCKER_BUILD_SCRIPT_PATH")"
assert_file_contains "$CI_DOCKER_LOG" "docker build --pull --build-arg BUILDKIT_INLINE_CACHE=1 --cache-from $default_image_ref:latest --cache-from $DEFAULT_BUILDER_IMAGE -f Dockerfile.ubuntu ."
assert_contains "$pr_target_branch_output" 'Build-only branch: not publishing image'
if grep -Fq -- "-t $DEFAULT_IMAGE_NAME:" "$CI_DOCKER_LOG"; then
    echo "Expected pull-request build-only CI run to avoid tagging the image." >&2
    exit 1
fi

: > "$CI_DOCKER_LOG"
publishable_build_output="$(PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_BRANCH=php85 bash "$CI_DOCKER_BUILD_SCRIPT_PATH")"
assert_file_contains "$CI_DOCKER_LOG" "docker build --pull --build-arg BUILDKIT_INLINE_CACHE=1 --cache-from $default_image_ref:php85 --cache-from $default_image_ref:latest --cache-from $DEFAULT_BUILDER_IMAGE -f Dockerfile.ubuntu -t $DEFAULT_IMAGE_NAME:php85 ."
assert_contains "$publishable_build_output" "Publishable ref built without publishing: $DEFAULT_IMAGE_NAME:php85"
if grep -Fq -- 'docker login' "$CI_DOCKER_LOG" || grep -Fq -- 'docker push' "$CI_DOCKER_LOG"; then
    echo "Expected CI build mode to avoid Docker login/push." >&2
    exit 1
fi

: > "$CI_DOCKER_LOG"
PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_BRANCH=php85 CI_DOCKER_MODE=build-publish DOCKER_PASSWORD=test bash "$CI_DOCKER_BUILD_SCRIPT_PATH"
assert_file_contains "$CI_DOCKER_LOG" "docker build --pull --build-arg BUILDKIT_INLINE_CACHE=1 --cache-from $default_image_ref:php85 --cache-from $default_image_ref:latest --cache-from $DEFAULT_BUILDER_IMAGE -f Dockerfile.ubuntu -t $DEFAULT_IMAGE_NAME:php85 ."
assert_file_contains "$CI_DOCKER_LOG" "docker login -u $DEFAULT_DOCKER_USERNAME --password-stdin"
assert_file_contains "$CI_DOCKER_LOG" "docker push $default_image_ref:php85"
if grep -Fq -- 'docker run --rm aquasec/trivy' "$CI_DOCKER_LOG"; then
    echo "Expected publish script not to run Trivy directly." >&2
    exit 1
fi

: > "$CI_DOCKER_LOG"
PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_BRANCH=php85 bash "$CI_TRIVY_SCAN_SCRIPT_PATH"
assert_file_contains "$CI_DOCKER_LOG" "docker run --rm aquasec/trivy:latest image --exit-code 0 --severity HIGH,CRITICAL $default_image_ref:php85"

: > "$CI_DOCKER_LOG"
failed_scan_output="$(PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_BRANCH=php85 TRIVY_IMAGE=failing-trivy bash "$CI_TRIVY_SCAN_SCRIPT_PATH" 2>&1)"
assert_contains "$failed_scan_output" "Warning: non-blocking Trivy scan failed for $default_image_ref:php85"
assert_file_contains "$CI_DOCKER_LOG" "docker run --rm failing-trivy image --exit-code 0 --severity HIGH,CRITICAL $default_image_ref:php85"

: > "$CI_DOCKER_LOG"
if PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_BRANCH=php85 CI_GIT_REF_TYPE=pull-request CI_DOCKER_MODE=build-publish DOCKER_PASSWORD=test bash "$CI_DOCKER_BUILD_SCRIPT_PATH" >"$PR_PUBLISH_OUTPUT" 2>&1; then
    echo "Expected pull-request build-publish mode to fail." >&2
    exit 1
fi
assert_file_contains "$PR_PUBLISH_OUTPUT" 'Refusing to publish from pull-request ref.'

: > "$CI_DOCKER_LOG"
if PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_TAG=latest CI_GIT_REF_TYPE=tag CI_DOCKER_MODE=build-publish DOCKER_PASSWORD=test bash "$CI_DOCKER_BUILD_SCRIPT_PATH" >"$TAG_PUBLISH_OUTPUT" 2>&1; then
    echo "Expected non-version tag publish to fail." >&2
    exit 1
fi
assert_file_contains "$TAG_PUBLISH_OUTPUT" 'Refusing to publish non-version tag: latest.'
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
