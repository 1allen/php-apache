#!/usr/bin/env bash
# shellcheck disable=SC2016

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS_PATH="$ROOT_DIR/AGENTS.md"
SCRIPT_PATH="$ROOT_DIR/scripts/repo_sync.sh"
TAGS_SCRIPT_PATH="$ROOT_DIR/scripts/tags_update.sh"
DOCKER_HUB_CLEANUP_SCRIPT_PATH="$ROOT_DIR/scripts/docker_hub_cleanup.sh"
IMAGE_METRICS_SCRIPT_PATH="$ROOT_DIR/scripts/image_metrics.sh"
CI_DOCKER_BUILD_SCRIPT_PATH="$ROOT_DIR/scripts/ci/docker_build.sh"
CI_TRIVY_SCAN_SCRIPT_PATH="$ROOT_DIR/scripts/ci/trivy_scan.sh"
CI_RELEASE_STATUS_SCRIPT_PATH="$ROOT_DIR/scripts/ci/release_status.sh"
CI_VERIFY_GITHUB_ACTION_PINS_SCRIPT_PATH="$ROOT_DIR/scripts/ci/verify_github_action_pins.sh"
CI_WAIT_FOR_PUBLISHED_IMAGE_SCRIPT_PATH="$ROOT_DIR/scripts/ci/wait_for_published_image.sh"
MANIFEST_PATH="$ROOT_DIR/config/php-branches.conf"
IMAGE_SIZE_BASELINE_PATH="$ROOT_DIR/config/image-size-baseline.tsv"
DOCKERFILE_PATH="$ROOT_DIR/Dockerfile.ubuntu"
README_PATH="$ROOT_DIR/README.md"
DOCS_README_PATH="$ROOT_DIR/docs/README.md"
MAINTENANCE_PATH="$ROOT_DIR/docs/maintenance.md"
DECISIONS_PATH="$ROOT_DIR/docs/decisions.md"
SEMAPHORE_PATH="$ROOT_DIR/.semaphore/semaphore.yml"
SEMAPHORE_PUBLISH_PATH="$ROOT_DIR/.semaphore/publish.yml"
GITHUB_CLEANUP_PATH="$ROOT_DIR/.github/workflows/docker-hub-cleanup.yml"
GITHUB_IMAGE_ANALYSIS_PATH="$ROOT_DIR/.github/workflows/image-analysis.yml"
RELEASE_REF_PATH="$ROOT_DIR/scripts/lib/release_ref.sh"
IMAGE_CONTRACT_PATH="$ROOT_DIR/scripts/lib/image_contract.sh"
GIT_WORKTREE_PATH="$ROOT_DIR/scripts/lib/git_worktree.sh"

# shellcheck disable=SC1091
source "$ROOT_DIR/tests/test_helper.sh"

[[ -f "$MANIFEST_PATH" ]] || {
    echo "Missing manifest: $MANIFEST_PATH" >&2
    exit 1
}

# shellcheck disable=SC1090
source "$MANIFEST_PATH"
# shellcheck disable=SC1090
source "$RELEASE_REF_PATH"
# shellcheck disable=SC1090
source "$IMAGE_CONTRACT_PATH"

[[ -x "$SCRIPT_PATH" ]] || {
    echo "Missing executable sync script: $SCRIPT_PATH" >&2
    exit 1
}

[[ -x "$TAGS_SCRIPT_PATH" ]] || {
    echo "Missing executable tags script: $TAGS_SCRIPT_PATH" >&2
    exit 1
}

[[ -x "$DOCKER_HUB_CLEANUP_SCRIPT_PATH" ]] || {
    echo "Missing executable Docker Hub cleanup script: $DOCKER_HUB_CLEANUP_SCRIPT_PATH" >&2
    exit 1
}

[[ -x "$IMAGE_METRICS_SCRIPT_PATH" ]] || {
    echo "Missing executable image metrics script: $IMAGE_METRICS_SCRIPT_PATH" >&2
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

[[ -x "$CI_RELEASE_STATUS_SCRIPT_PATH" ]] || {
    echo "Missing executable release status script: $CI_RELEASE_STATUS_SCRIPT_PATH" >&2
    exit 1
}

[[ -x "$CI_WAIT_FOR_PUBLISHED_IMAGE_SCRIPT_PATH" ]] || {
    echo "Missing executable published-image wait script: $CI_WAIT_FOR_PUBLISHED_IMAGE_SCRIPT_PATH" >&2
    exit 1
}

test_temp_dir TMP_RELEASE_STATUS release-status
mkdir -p "$TMP_RELEASE_STATUS/bin"
cat > "$TMP_RELEASE_STATUS/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == "api" ]] || exit 64
case "${MOCK_RELEASE_STATE:-success}" in
    missing)
        printf '%s\n' '{"statuses":[]}'
        ;;
    *)
        printf '{"statuses":[{"context":"ci/semaphoreci/tag: php-apache build pipeline","state":"%s","target_url":"https://ci.example/release"}]}\n' \
            "${MOCK_RELEASE_STATE:-success}"
        ;;
esac
EOF
chmod +x "$TMP_RELEASE_STATUS/bin/gh"

release_status_output="$(
    GITHUB_REPOSITORY=1allen/php-apache \
    GH_BIN="$TMP_RELEASE_STATUS/bin/gh" \
    bash "$CI_RELEASE_STATUS_SCRIPT_PATH" HEAD
)"
assert_contains "$release_status_output" $'HEAD\tsuccess\thttps://ci.example/release'

set +e
release_status_output="$(
    GITHUB_REPOSITORY=1allen/php-apache \
    GH_BIN="$TMP_RELEASE_STATUS/bin/gh" \
    MOCK_RELEASE_STATE=pending \
    bash "$CI_RELEASE_STATUS_SCRIPT_PATH" HEAD
)"
release_status_exit=$?
set -e
[[ "$release_status_exit" -eq 2 ]] || {
    echo "Expected pending release status to exit 2, got $release_status_exit." >&2
    exit 1
}
assert_contains "$release_status_output" $'HEAD\tpending\thttps://ci.example/release'

set +e
GITHUB_REPOSITORY=1allen/php-apache \
GH_BIN="$TMP_RELEASE_STATUS/bin/gh" \
MOCK_RELEASE_STATE=failure \
bash "$CI_RELEASE_STATUS_SCRIPT_PATH" HEAD >/dev/null
release_status_exit=$?
set -e
[[ "$release_status_exit" -eq 1 ]] || {
    echo "Expected failed release status to exit 1, got $release_status_exit." >&2
    exit 1
}

test_temp_dir TMP_PUBLISHED_IMAGE published-image
mkdir -p "$TMP_PUBLISHED_IMAGE/bin"
cat > "$TMP_PUBLISHED_IMAGE/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

count=0
if [[ -f "$MOCK_PUBLISHED_IMAGE_COUNT" ]]; then
    count="$(<"$MOCK_PUBLISHED_IMAGE_COUNT")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$MOCK_PUBLISHED_IMAGE_COUNT"

case "${MOCK_PUBLISHED_IMAGE_MODE:-current}" in
    current)
        updated=2026-07-20T12:00:00Z
        ;;
    stale-then-current)
        if [[ $count -eq 1 ]]; then
            updated=2026-07-19T12:00:00Z
        else
            updated=2026-07-20T12:00:00Z
        fi
        ;;
    missing)
        exit 22
        ;;
    *)
        exit 64
        ;;
esac

printf '{"digest":"sha256:test-%s","last_updated":"%s"}\n' "$count" "$updated"
EOF
chmod +x "$TMP_PUBLISHED_IMAGE/bin/curl"

published_image_output="$(
    CURL_BIN="$TMP_PUBLISHED_IMAGE/bin/curl" \
    MOCK_PUBLISHED_IMAGE_COUNT="$TMP_PUBLISHED_IMAGE/count" \
    bash "$CI_WAIT_FOR_PUBLISHED_IMAGE_SCRIPT_PATH" \
        --digest-file "$TMP_PUBLISHED_IMAGE/digest" \
        --updated-after 1784500000 8.5
)"
assert_contains "$published_image_output" 'Published image ready: 1allen/php-apache:8.5'
assert_file_contains "$TMP_PUBLISHED_IMAGE/digest" 'sha256:test-1'

rm -f "$TMP_PUBLISHED_IMAGE/count"
published_image_output="$(
    CURL_BIN="$TMP_PUBLISHED_IMAGE/bin/curl" \
    MOCK_PUBLISHED_IMAGE_COUNT="$TMP_PUBLISHED_IMAGE/count" \
    MOCK_PUBLISHED_IMAGE_MODE=stale-then-current \
    bash "$CI_WAIT_FOR_PUBLISHED_IMAGE_SCRIPT_PATH" \
        --wait --interval 1 --timeout 2 --updated-after 1784500000 8.5
)"
assert_contains "$published_image_output" 'Waiting for published image: 1allen/php-apache:8.5'
assert_contains "$published_image_output" 'Published image ready: 1allen/php-apache:8.5'

set +e
bash "$CI_WAIT_FOR_PUBLISHED_IMAGE_SCRIPT_PATH" --interval 0 8.5 >/dev/null 2>&1
published_image_exit=$?
set -e
[[ "$published_image_exit" -eq 3 ]] || {
    echo "Expected a zero polling interval to exit 3, got $published_image_exit." >&2
    exit 1
}

rm -f "$TMP_PUBLISHED_IMAGE/count"
set +e
CURL_BIN="$TMP_PUBLISHED_IMAGE/bin/curl" \
MOCK_PUBLISHED_IMAGE_COUNT="$TMP_PUBLISHED_IMAGE/count" \
MOCK_PUBLISHED_IMAGE_MODE=missing \
bash "$CI_WAIT_FOR_PUBLISHED_IMAGE_SCRIPT_PATH" \
    --wait --interval 1 --timeout 0 8.5 >/dev/null
published_image_exit=$?
set -e
[[ "$published_image_exit" -eq 2 ]] || {
    echo "Expected missing published image to exit 2, got $published_image_exit." >&2
    exit 1
}

status_output="$(bash "$SCRIPT_PATH" status)"
assert_contains "$status_output" "Configured PHP branches:"
assert_contains "$status_output" "php85"
assert_contains "$status_output" ".semaphore/semaphore.yml"
assert_contains "$status_output" ".semaphore/publish.yml"
assert_contains "$status_output" ".github/workflows/docker-hub-cleanup.yml"
assert_contains "$status_output" ".dockerignore"
assert_contains "$status_output" "AGENTS.md"
assert_contains "$status_output" "docs/maintenance.md"
assert_contains "$status_output" "scripts/ci/docker_build.sh"
assert_contains "$status_output" "scripts/ci/trivy_scan.sh"
assert_contains "$status_output" "scripts/ci/release_status.sh"
assert_contains "$status_output" "scripts/ci/verify_github_action_pins.sh"
assert_contains "$status_output" "scripts/ci/wait_for_published_image.sh"
assert_contains "$status_output" "scripts/image_metrics.sh"
assert_contains "$status_output" "scripts/docker_hub_cleanup.sh"
assert_contains "$status_output" "config/image-size-baseline.tsv"

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
assert_file_contains "$MANIFEST_PATH" 'PHP_EXTENSION_INSTALLER_IMAGE="ghcr.io/mlocati/php-extension-installer:latest"'

[[ -n "$PUBLISH_TAG_PATTERN" && -n "$PHP_BRANCH_PATTERN" ]] || {
    echo "Expected release-ref patterns to be configured." >&2
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

assert_file_contains "$IMAGE_SIZE_BASELINE_PATH" $'php80\tsha256:4a971067e24945343795f25be39da922ade64270ff25e61928051e392dd8d3aa\t528402850'
assert_file_contains "$IMAGE_SIZE_BASELINE_PATH" $'php85\tsha256:62aebc2ea3adb603f438814f73914dcb822acffe2130bfcc537212d749ef7501\t645640060'

test_temp_dir TMP_IMAGE_METRICS image-metrics
metrics_api_root="$TMP_IMAGE_METRICS/1allen/php-apache/tags"
mkdir -p "$metrics_api_root"

cat > "$metrics_api_root/8.5" <<'EOF'
{"digest":"sha256:current-php85","images":[{"architecture":"amd64","os":"linux","size":600000000}]}
EOF

metrics_output="$(DOCKER_HUB_API_BASE="file://$TMP_IMAGE_METRICS" bash "$IMAGE_METRICS_SCRIPT_PATH" --format tsv 8.5)"
assert_contains "$metrics_output" $'tag\tbaseline_bytes\tcurrent_bytes\tsaved_bytes\tsaved_percent\tcurrent_digest\tbaseline_digest\tbaseline_tag_last_updated'
assert_contains "$metrics_output" $'8.5\t645640060\t600000000\t45640060\t7.07\tsha256:current-php85'
assert_contains "$metrics_output" $'TOTAL\t645640060\t600000000\t45640060\t7.07\t-\t-\t-'

metrics_markdown="$(DOCKER_HUB_API_BASE="file://$TMP_IMAGE_METRICS" bash "$IMAGE_METRICS_SCRIPT_PATH" 8.5)"
assert_contains "$metrics_markdown" '| 8.5 | 615.7 MiB | 572.2 MiB | 43.5 MiB | 7.07% | sha256:current-php85 |'
assert_contains "$metrics_markdown" '| **Total (1 tag)** | **615.7 MiB** | **572.2 MiB** | **43.5 MiB** | **7.07%** | - |'

BUILD_METRICS_FIXTURE="$TMP_IMAGE_METRICS/build-metrics.tsv"
cat > "$BUILD_METRICS_FIXTURE" <<'EOF'
tag	cache_prepare_seconds	build_seconds	publish_seconds	total_seconds	cache_sources
8.5	3	42	7	55	1allen/php-apache:8.5,spritsail/debian-builder:latest
EOF

timed_metrics_output="$(DOCKER_HUB_API_BASE="file://$TMP_IMAGE_METRICS" bash "$IMAGE_METRICS_SCRIPT_PATH" --build-metrics "$BUILD_METRICS_FIXTURE" --format tsv 8.5)"
assert_contains "$timed_metrics_output" $'tag\tcache_prepare_seconds\tbuild_seconds\tpublish_seconds\ttotal_seconds\tbaseline_bytes\tcurrent_bytes\tsaved_bytes\tsaved_percent\tcurrent_digest\tbaseline_digest\tbaseline_tag_last_updated\tcache_sources'
assert_contains "$timed_metrics_output" $'8.5\t3\t42\t7\t55\t645640060\t600000000\t45640060\t7.07\tsha256:current-php85\tsha256:62aebc2ea3adb603f438814f73914dcb822acffe2130bfcc537212d749ef7501\t2026-06-28T16:59:25.063933Z\t1allen/php-apache:8.5,spritsail/debian-builder:latest'

timed_metrics_markdown="$(DOCKER_HUB_API_BASE="file://$TMP_IMAGE_METRICS" bash "$IMAGE_METRICS_SCRIPT_PATH" --build-metrics "$BUILD_METRICS_FIXTURE" 8.5)"
assert_contains "$timed_metrics_markdown" '| Tag | Cache prep | Build | Publish | Total | Baseline | Current | Saved | Saved % | Current digest | Cache sources |'
assert_contains "$timed_metrics_markdown" '| 8.5 | 3s | 42s | 7s | 55s | 615.7 MiB | 572.2 MiB | 43.5 MiB | 7.07% | sha256:current-php85 | 1allen/php-apache:8.5, spritsail/debian-builder:latest |'

INVALID_BUILD_METRICS_FIXTURE="$TMP_IMAGE_METRICS/invalid-build-metrics.tsv"
cat > "$INVALID_BUILD_METRICS_FIXTURE" <<'EOF'
tag	cache_prepare_seconds	build_seconds	publish_seconds	total_seconds	cache_sources
8.5	3	not-a-number	7	55	1allen/php-apache:8.5
EOF
if DOCKER_HUB_API_BASE="file://$TMP_IMAGE_METRICS" bash "$IMAGE_METRICS_SCRIPT_PATH" --build-metrics "$INVALID_BUILD_METRICS_FIXTURE" 8.5 >"$TMP_IMAGE_METRICS/invalid-build-metrics.out" 2>&1; then
    echo "Expected image metrics to reject an invalid build timing record." >&2
    exit 1
fi
assert_file_contains "$TMP_IMAGE_METRICS/invalid-build-metrics.out" 'Missing valid build metrics for tag: 8.5'

cat > "$metrics_api_root/8.4" <<'EOF'
{"digest":"sha256:arm-only","images":[{"architecture":"arm64","os":"linux","size":1234}]}
EOF

if DOCKER_HUB_API_BASE="file://$TMP_IMAGE_METRICS" bash "$IMAGE_METRICS_SCRIPT_PATH" --format tsv 8.4 >"$TMP_IMAGE_METRICS/missing-amd64.out" 2>&1; then
    echo "Expected image metrics to reject metadata without linux/amd64 size." >&2
    exit 1
fi
assert_file_contains "$TMP_IMAGE_METRICS/missing-amd64.out" 'Missing linux/amd64 digest or size'

test_temp_dir TMP_DOCKER_HUB_CLEANUP docker-hub-cleanup
mkdir -p "$TMP_DOCKER_HUB_CLEANUP/bin"
DOCKER_HUB_CURL_LOG="$TMP_DOCKER_HUB_CLEANUP/curl.log"
DOCKER_HUB_CLEANUP_STATE="$TMP_DOCKER_HUB_CLEANUP/deleted"
export DOCKER_HUB_CURL_LOG DOCKER_HUB_CLEANUP_STATE

cat > "$TMP_DOCKER_HUB_CLEANUP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

method=GET
url=""

for argument in "$@"; do
    if [[ "$argument" == *test-secret* || "$argument" == *test-bearer* ]]; then
        echo "Docker Hub credential leaked through curl arguments." >&2
        exit 1
    fi
done

while [[ $# -gt 0 ]]; do
    case "$1" in
        -X|--request)
            method="$2"
            shift 2
            ;;
        -d|--data|--data-raw|--data-binary|-H|--header|-o|--output|-w|--write-out|--connect-timeout|--retry|--config)
            shift 2
            ;;
        http://*|https://*)
            url="$1"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

printf '%s\t%s\n' "$method" "$url" >>"$DOCKER_HUB_CURL_LOG"

case "$url" in
    */auth/token)
        printf '%s\n' '{"access_token":"test-bearer"}'
        ;;
    *'/tags?page_size=100')
        if [[ -f "$DOCKER_HUB_CLEANUP_STATE" ]]; then
            printf '%s\n' '{"next":"https://hub.test/v2/page/2","results":[{"name":"8.5","digest":"sha256:85","last_updated":"2026-07-17T00:00:00Z"}]}'
        else
            printf '%s\n' '{"next":"https://hub.test/v2/page/2","results":[{"name":"latest","digest":"sha256:latest","last_updated":"2026-07-17T00:00:00Z"},{"name":"php73","digest":"sha256:php73","last_updated":"2026-07-17T00:00:00Z"},{"name":"php74","digest":"sha256:php74","last_updated":"2026-07-17T00:00:00Z"},{"name":"php80","digest":"sha256:php80","last_updated":"2026-07-17T00:00:00Z"},{"name":"php81","digest":"sha256:php81","last_updated":"2026-07-17T00:00:00Z"},{"name":"php82","digest":"sha256:php82","last_updated":"2026-07-17T00:00:00Z"},{"name":"php83","digest":"sha256:php83","last_updated":"2026-07-17T00:00:00Z"},{"name":"php84","digest":"sha256:php84","last_updated":"2026-07-17T00:00:00Z"},{"name":"php85","digest":"sha256:php85","last_updated":"2026-07-17T00:00:00Z"},{"name":"8.5","digest":"sha256:85","last_updated":"2026-07-17T00:00:00Z"}]}'
        fi
        ;;
    */page/2)
        printf '%s\n' '{"next":null,"results":[{"name":"8.5.1","digest":"sha256:851","last_updated":"2026-07-17T00:00:00Z"},{"name":"canary","digest":"sha256:canary","last_updated":"2026-07-17T00:00:00Z"}]}'
        ;;
    */tags/*)
        [[ "$method" == DELETE ]] || exit 1
        : >"$DOCKER_HUB_CLEANUP_STATE"
        ;;
    *)
        echo "Unexpected fake Docker Hub request: $method $url" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$TMP_DOCKER_HUB_CLEANUP/bin/curl"

cleanup_preview="$(PATH="$TMP_DOCKER_HUB_CLEANUP/bin:$PATH" DOCKER_HUB_API_BASE=https://hub.test/v2 bash "$DOCKER_HUB_CLEANUP_SCRIPT_PATH")"
assert_contains "$cleanup_preview" 'Retired Docker Hub tags present:'
for retired_tag in latest php73 php74 php80 php81 php82 php83 php84 php85; do
    assert_contains "$cleanup_preview" "$retired_tag"
done
assert_contains "$cleanup_preview" 'Preserved version-like tags:'
assert_contains "$cleanup_preview" '8.5'
assert_contains "$cleanup_preview" '8.5.1'
assert_contains "$cleanup_preview" 'Other untouched tags:'
assert_contains "$cleanup_preview" 'canary'
assert_contains "$cleanup_preview" 'Dry run: no Docker Hub tags were deleted.'
if grep -Eq $'^(POST|DELETE)\t' "$DOCKER_HUB_CURL_LOG"; then
    echo "Expected Docker Hub cleanup dry run to avoid authentication and deletion." >&2
    exit 1
fi

if PATH="$TMP_DOCKER_HUB_CLEANUP/bin:$PATH" DOCKER_HUB_API_BASE=https://hub.test/v2 bash "$DOCKER_HUB_CLEANUP_SCRIPT_PATH" --apply >"$TMP_DOCKER_HUB_CLEANUP/missing-token.out" 2>&1; then
    echo "Expected Docker Hub cleanup apply mode to require a token." >&2
    exit 1
fi
assert_file_contains "$TMP_DOCKER_HUB_CLEANUP/missing-token.out" 'DOCKER_HUB_TOKEN is required with --apply.'

: >"$DOCKER_HUB_CURL_LOG"
rm -f "$DOCKER_HUB_CLEANUP_STATE"
cleanup_apply="$(PATH="$TMP_DOCKER_HUB_CLEANUP/bin:$PATH" DOCKER_HUB_API_BASE=https://hub.test/v2 DOCKER_HUB_TOKEN=test-secret bash "$DOCKER_HUB_CLEANUP_SCRIPT_PATH" --apply)"
assert_contains "$cleanup_apply" 'Docker Hub cleanup verified: no retired tags remain.'
assert_file_contains "$DOCKER_HUB_CURL_LOG" $'POST\thttps://hub.test/v2/auth/token'
for retired_tag in latest php73 php74 php80 php81 php82 php83 php84 php85; do
    assert_file_contains "$DOCKER_HUB_CURL_LOG" $'DELETE\thttps://hub.test/v2/namespaces/1allen/repositories/php-apache/tags/'"$retired_tag"
done
if grep -Eq $'DELETE\t.*/tags/[0-9]+[.][0-9]+' "$DOCKER_HUB_CURL_LOG"; then
    echo "Expected Docker Hub cleanup never to delete version-like tags." >&2
    exit 1
fi
delete_count="$(awk -F '\t' '$1 == "DELETE" { count++ } END { print count + 0 }' "$DOCKER_HUB_CURL_LOG")"
[[ "$delete_count" -eq 9 ]] || {
    echo "Expected exactly 9 retired Docker Hub tag deletions, got $delete_count." >&2
    exit 1
}

: >"$DOCKER_HUB_CURL_LOG"
cleanup_idempotent="$(PATH="$TMP_DOCKER_HUB_CLEANUP/bin:$PATH" DOCKER_HUB_API_BASE=https://hub.test/v2 bash "$DOCKER_HUB_CLEANUP_SCRIPT_PATH" --apply)"
assert_contains "$cleanup_idempotent" 'Docker Hub cleanup verified: no retired tags remain.'
if grep -Eq $'^(POST|DELETE)\t' "$DOCKER_HUB_CURL_LOG"; then
    echo "Expected an already-clean Docker Hub apply run to avoid authentication and deletion." >&2
    exit 1
fi

assert_file_contains "$README_PATH" 'bash scripts/image_metrics.sh'
assert_file_contains "$README_PATH" 'bash scripts/docker_hub_cleanup.sh'
assert_file_contains "$README_PATH" 'bash scripts/repo_sync.sh sync-shared --push'
assert_file_contains "$DOCS_README_PATH" 'config/image-size-baseline.tsv'
assert_file_contains "$DOCS_README_PATH" 'scripts/docker_hub_cleanup.sh'
assert_file_contains "$MAINTENANCE_PATH" 'pre-cleanup Docker Hub snapshot'
assert_file_contains "$MAINTENANCE_PATH" 'bash scripts/docker_hub_cleanup.sh --apply'
assert_file_contains "$MAINTENANCE_PATH" 'Docker Hub cleanup workflow'
assert_file_contains "$MAINTENANCE_PATH" 'write access to the repository'
assert_file_contains "$MAINTENANCE_PATH" 'safe to rerun'
assert_file_contains "$MAINTENANCE_PATH" 'should automatically delete merged pull-request head'
assert_file_contains "$DECISIONS_PATH" 'manual GitHub Actions workflow'
assert_file_contains "$README_PATH" 'manual GitHub Actions cleanup workflow'
assert_file_contains "$MAINTENANCE_PATH" 'bash scripts/repo_sync.sh sync-shared --push'
assert_file_contains "$DECISIONS_PATH" 'Measure Registry-Compressed Image Size'
assert_file_contains "$DECISIONS_PATH" 'Automate Repeatable External Effects Behind Apply Gates'
assert_file_contains "$README_PATH" 'Shared maintenance commits do not require rebuilding or moving these tags'
assert_file_contains "$MAINTENANCE_PATH" 'The retired Docker Hub tags have been removed'
assert_file_contains "$MAINTENANCE_PATH" 'Build timings remain available in the Semaphore publish-job log'
assert_file_contains "$MAINTENANCE_PATH" 'Do not move version tags after documentation, test, or CI-adapter-only changes'
assert_file_contains "$DECISIONS_PATH" 'Version tags identify published image revisions, not every maintenance commit'
assert_file_contains "$DECISIONS_PATH" '1,991 seconds to 929 seconds'
assert_file_contains "$AGENTS_PATH" 'Do not move version tags after documentation, test, or CI-adapter-only changes'

assert_file_contains "$DOCKERFILE_PATH" 'curl -fsSL --retry 5 --retry-connrefused --connect-timeout 15'
assert_file_contains "$DOCKERFILE_PATH" 'sha256sum -c -'
assert_file_contains "$DOCKERFILE_PATH" 'PKG_CONFIG_PATH=/usr/local/lib/pkgconfig'
assert_file_contains "$DOCKERFILE_PATH" 'make install DESTDIR=/tmp/imgck'
assert_file_contains "$DOCKERFILE_PATH" "find /tmp/imgck/usr/local/lib -type f"
assert_file_contains "$DOCKERFILE_PATH" 'COPY --chown=$UID:$GID --from=imagemagick-builder /tmp/imgck/usr/local/ /usr/local/'
assert_file_contains "$DOCKERFILE_PATH" 'FROM ${PHP_EXTENSION_INSTALLER_IMAGE} AS php-extension-installer'
assert_file_contains "$DOCKERFILE_PATH" 'COPY --from=php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/'
assert_file_contains "$DOCKERFILE_PATH" 'docker-php-ext-configure imagick --with-imagick=/usr/local'
assert_file_contains "$DOCKERFILE_PATH" '--without-x'
assert_file_contains "$DOCKERFILE_PATH" 'libwebp7'
assert_file_contains "$DOCKERFILE_PATH" 'libwebpdemux2'
assert_file_contains "$DOCKERFILE_PATH" 'libwebpmux3'
assert_file_contains "$DOCKERFILE_PATH" 'magick -size 2x2 xc:white /tmp/webp-contract.webp'
assert_file_contains "$DOCKERFILE_PATH" 'Imagick::queryFormats("WEBP")'
assert_file_not_contains "$DOCKERFILE_PATH" "        jpegoptim \\"
assert_file_not_contains "$DOCKERFILE_PATH" "        mariadb-client \\"
assert_file_not_contains "$DOCKERFILE_PATH" "        webp \\"
assert_file_not_contains "$DOCKERFILE_PATH" "        ffmpeg \\"
assert_file_not_contains "$DOCKERFILE_PATH" "        libxt6 \\"
assert_file_contains "$ROOT_DIR/README.md" '## Downstream Customization'
for optional_package in jpegoptim webp ffmpeg mariadb-client; do
    assert_file_contains "$ROOT_DIR/README.md" "$optional_package"
done
assert_file_contains "$DOCKERFILE_PATH" 'ioncube_ini=/usr/local/etc/php/conf.d/00-ioncube.ini'
assert_file_contains "$DOCKERFILE_PATH" 'ldd "$ioncube_loader"'
assert_file_contains "$DOCKERFILE_PATH" 'groupmod -g "$GID" application'
assert_file_contains "$README_PATH" '## Features'
assert_file_contains "$README_PATH" '## Useful Build Improvements'
assert_file_contains "$README_PATH" 'newer pinned ImageMagick built under `/usr/local`'
assert_file_contains "$README_PATH" 'with verified WebP support'
assert_file_contains "$README_PATH" '`install-php-extensions` available'
assert_file_contains "$README_PATH" '## Supported Images'
assert_file_contains "$README_PATH" '## Quick Start'
assert_file_contains "$README_PATH" '## Rootless Docker'
assert_file_contains "$README_PATH" '## Repository Development'
assert_file_contains "$README_PATH" '## Project Documentation'
assert_file_contains "$README_PATH" 'CONTAINER_UID: "0"'
assert_file_contains "$README_PATH" 'SERVICE_PHPFPM_OPTS: "-R"'
assert_file_contains "$DOCS_README_PATH" '**Rootless Docker daemon**'
assert_file_contains "$MAINTENANCE_PATH" '## Rootless Docker Bind Mounts'
assert_file_contains "$MAINTENANCE_PATH" 'user: "0:0"'
assert_file_contains "$MAINTENANCE_PATH" 'CONTAINER_UID: "0"'
assert_file_contains "$MAINTENANCE_PATH" 'SERVICE_PHPFPM_OPTS: "-R"'
assert_file_contains "$MAINTENANCE_PATH" 'Do not use this mode with a rootful Docker daemon.'
assert_file_contains "$DECISIONS_PATH" '## Use One Image For Rootless Docker'
assert_file_contains "$AGENTS_PATH" 'Treat the documented maintenance interfaces as authoritative'
assert_file_contains "$AGENTS_PATH" 'PHP branches are preflight-only'
assert_file_contains "$MAINTENANCE_PATH" '## Workflow Change Gate'
assert_file_contains "$MAINTENANCE_PATH" 'Version-like Git tags are the only Docker Hub publish refs.'
assert_file_contains "$DECISIONS_PATH" '## Use Existing Maintenance Interfaces First'
assert_file_contains "$DECISIONS_PATH" '## Publish Version Tags Once'
assert_file_contains "$DECISIONS_PATH" '## Join Build And Image Metrics At A File Seam'
assert_file_contains "$DOCS_README_PATH" '**Release-source preflight**'
assert_file_contains "$README_PATH" 'Published PHP images come only from version-like Git tags.'
assert_file_contains "$MAINTENANCE_PATH" 'bash scripts/image_metrics.sh --build-metrics /tmp/php-apache-build-metrics.tsv'
assert_file_contains "$SEMAPHORE_PATH" 'type: e1-standard-2'
assert_file_contains "$SEMAPHORE_PATH" 'os_image: ubuntu2404'
assert_file_contains "$SEMAPHORE_PATH" 'global_job_config:'
assert_file_contains "$SEMAPHORE_PATH" 'prologue:'
assert_file_contains "$SEMAPHORE_PATH" 'checkout'
assert_file_contains "$SEMAPHORE_PATH" 'name: build image'
assert_file_contains "$SEMAPHORE_PATH" "pull_request =~ '^.+$' OR branch = 'latest'"
assert_file_contains "$SEMAPHORE_PATH" 'name: verify release source'
assert_file_contains "$SEMAPHORE_PATH" "pull_request !~ '^.+$' AND (branch =~ '^php[0-9][0-9]$' OR tag =~ '$PUBLISH_TAG_PATTERN')"
assert_file_contains "$SEMAPHORE_PATH" 'CI_GIT_BRANCH="${SEMAPHORE_GIT_BRANCH:-}"'
assert_file_contains "$SEMAPHORE_PATH" 'CI_GIT_TAG="${SEMAPHORE_GIT_TAG_NAME:-}"'
assert_file_contains "$SEMAPHORE_PATH" 'CI_GIT_REF_TYPE="${SEMAPHORE_GIT_REF_TYPE:-}"'
assert_file_contains "$SEMAPHORE_PATH" 'bash scripts/ci/verify_github_action_pins.sh .github/workflows/image-analysis.yml'
assert_file_contains "$SEMAPHORE_PATH" 'bash scripts/ci/docker_build.sh'
assert_file_contains "$SEMAPHORE_PATH" 'name: CI_DOCKER_MODE'
assert_file_contains "$SEMAPHORE_PATH" 'value: build'
assert_file_contains "$SEMAPHORE_PATH" 'value: preflight'
assert_file_contains "$SEMAPHORE_PATH" 'promotions:'
assert_file_contains "$SEMAPHORE_PATH" 'name: publish final image'
assert_file_contains "$SEMAPHORE_PATH" 'pipeline_file: publish.yml'
assert_file_contains "$SEMAPHORE_PATH" "result = 'passed' AND pull_request !~ '^.+$' AND tag =~ '$PUBLISH_TAG_PATTERN'"
assert_file_not_contains "$SEMAPHORE_PATH" '*run_docker_ci'
assert_file_not_contains "$SEMAPHORE_PATH" '&run_docker_ci'

assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'name: php-apache publish pipeline'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'name: publish image'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'name: scan published image'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'dependencies:'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" '- publish image'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'bash scripts/ci/docker_build.sh'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'bash scripts/ci/trivy_scan.sh'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'name: CI_DOCKER_MODE'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'value: build-publish'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'dockerhub-1allen'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'CI_BUILD_METRICS_FILE=/tmp/php-apache-build-metrics.tsv'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'if ! bash scripts/image_metrics.sh --build-metrics /tmp/php-apache-build-metrics.tsv; then'
assert_file_contains "$SEMAPHORE_PUBLISH_PATH" 'Warning: release metrics report failed'
assert_file_not_contains "$SEMAPHORE_PUBLISH_PATH" '*run_docker_ci'
assert_file_not_contains "$SEMAPHORE_PUBLISH_PATH" '&run_docker_ci'

[[ -f "$GITHUB_CLEANUP_PATH" ]] || {
    echo "Missing GitHub Actions cleanup workflow: $GITHUB_CLEANUP_PATH" >&2
    exit 1
}

assert_file_contains "$GITHUB_CLEANUP_PATH" 'workflow_dispatch:'
assert_file_contains "$GITHUB_CLEANUP_PATH" 'contents: read'
assert_file_contains "$GITHUB_CLEANUP_PATH" 'cancel-in-progress: false'
assert_file_contains "$GITHUB_CLEANUP_PATH" 'uses: actions/checkout@v6'
assert_file_not_contains "$GITHUB_CLEANUP_PATH" 'uses: actions/checkout@v4'
assert_file_contains "$GITHUB_CLEANUP_PATH" 'test "$GITHUB_REF" = refs/heads/latest'
assert_file_contains "$GITHUB_CLEANUP_PATH" 'DOCKER_HUB_TOKEN: ${{ secrets.DOCKER_HUB_TOKEN }}'
assert_file_contains "$GITHUB_CLEANUP_PATH" 'bash scripts/docker_hub_cleanup.sh --apply'
assert_file_not_contains "$GITHUB_CLEANUP_PATH" 'push:'
assert_file_not_contains "$GITHUB_CLEANUP_PATH" 'pull_request:'
assert_file_not_contains "$GITHUB_CLEANUP_PATH" 'schedule:'
assert_file_not_contains "$SEMAPHORE_PATH" 'pipeline_file: cleanup.yml'

[[ -f "$GITHUB_IMAGE_ANALYSIS_PATH" ]] || {
    echo "Missing GitHub Actions image analysis workflow: $GITHUB_IMAGE_ANALYSIS_PATH" >&2
    exit 1
}

ruby - "$GITHUB_IMAGE_ANALYSIS_PATH" <<'RUBY'
require "yaml"

workflow = YAML.load_file(ARGV.fetch(0))
triggers = workflow["on"] || workflow[true] or abort "Missing workflow triggers"
abort "Missing tag push trigger" unless triggers.key?("push")
abort "Missing workflow_dispatch trigger" unless triggers.key?("workflow_dispatch")
jobs = workflow.fetch("jobs")
analyze = jobs["analyze"] or abort "Missing analyze job"
comment = jobs["comment"] or abort "Missing comment job"
abort "Analyze job permissions must stay read-only except for SARIF" unless analyze.fetch("permissions") == {
    "contents" => "read",
    "security-events" => "write",
}
abort "Comment job must isolate contents write permission" unless comment.fetch("permissions") == {
    "contents" => "write",
}
abort "Comment job must depend on analysis" unless comment.fetch("needs") == "analyze"
abort "Comment delivery must remain advisory" unless comment["continue-on-error"] == true
dive = analyze.fetch("steps").find { |step| step["id"] == "dive" } or abort "Missing Dive step"
abort "Dive must remain advisory" unless dive["continue-on-error"] == true

uses = []
walk = lambda do |value|
    case value
    when Hash
        value.each do |key, child|
            uses << child if key == "uses"
            walk.call(child)
        end
    when Array
        value.each { |child| walk.call(child) }
    end
end
walk.call(workflow)
abort "Workflow has no actions" if uses.empty?
invalid = uses.reject { |ref| ref.is_a?(String) && ref.match?(%r{\A[^@\s]+@[0-9a-f]{40}\z}) }
abort "Actions must use full commit pins: #{invalid.join(", ")}" unless invalid.empty?
RUBY

assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'workflow_dispatch:'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" "tags:"
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" "- '*.*'"
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'security-events: write'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'timeout-minutes: 70'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'persist-credentials: false'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" "ref: \${{ github.event_name == 'workflow_dispatch' && github.event.repository.default_branch || github.ref }}"
assert_file_not_contains "$GITHUB_IMAGE_ANALYSIS_PATH" "ref: \${{ github.event_name == 'workflow_dispatch' && inputs.tag || github.ref }}"
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'source scripts/lib/release_ref.sh'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'source_branch=$(release_ref_version_to_branch "$REQUESTED_TAG")'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'sha=$(git rev-parse "refs/tags/$REQUESTED_TAG^{commit}")'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" "if: github.event_name == 'push'"
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'bash scripts/ci/release_status.sh --wait'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'RELEASE_TAG: ${{ steps.image.outputs.tag }}'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'wait_args=(--wait --digest-file "$DIGEST_FILE")'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'bash scripts/ci/wait_for_published_image.sh'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" '--updated-after "$PUSHED_AT"'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" '--digest-file "$DIGEST_FILE"'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'echo "ref=$IMAGE_REPOSITORY@$digest"'
assert_file_not_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'MaxymVlasov/dive-action@'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'DIVE_IMAGE: ghcr.io/wagoodman/dive:v0.13.1@sha256:f1886e6c32c094fc41a623c1989f5cb3e48aa766da5f0be233f911fc1d85ce10'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'docker run --pull=always'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'dive_status=${PIPESTATUS[0]}'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" "echo '## Dive layer efficiency'"
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'echo "- Efficiency: $dive_efficiency"'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'echo "- Wasted bytes: $dive_wasted_bytes"'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'echo "- User-wasted ratio: $dive_wasted_ratio"'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'echo "- Threshold evaluation: $dive_verdict"'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" "echo '<details><summary>Full Dive report</summary>'"
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'cat "$clean_report"'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" "echo '</details>'"
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'exit "$dive_status"'
assert_file_not_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'github-token:'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'docker/scout-action@bacf462e8d090c09660de30a6ccc718035f961e3'
assert_file_not_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'docker/scout-action@481412c8b8de36d0f79e85aa382c60397466feb6'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'command: cves,recommendations'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'dockerhub-user: ${{ steps.image.outputs.namespace }}'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'DOCKER_HUB_TOKEN: ${{ secrets.DOCKER_HUB_TOKEN }}'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'run: test -n "$DOCKER_HUB_TOKEN"'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'dockerhub-password: ${{ secrets.DOCKER_HUB_TOKEN }}'
assert_file_not_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'DOCKER_SCOUT_TOKEN'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'only-severities: critical,high'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'only-fixed: true'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'write-comment: false'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'sarif-file: docker-scout.sarif'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'id: sarif'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'github/codeql-action/upload-sarif@7188fc363630916deb702c7fdcf4e481b751f97a'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'ref: refs/heads/${{ steps.image.outputs.source_branch }}'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'sha: ${{ steps.image.outputs.sha }}'
assert_file_not_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'github/codeql-action/upload-sarif@eec0bff2f6c15bf3f1e8a0152f94d17664a06a06'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'SARIF_OUTCOME: ${{ steps.sarif.outcome }}'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'published-image-analysis:${TAG}'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'commits/$SOURCE_SHA/comments'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'gh api --method PATCH'
assert_file_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'Dive is advisory and does not block publication.'
assert_file_not_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'docker build'
assert_file_not_contains "$GITHUB_IMAGE_ANALYSIS_PATH" 'docker push'

test_temp_dir TMP_ACTION_PINS github-action-pins
mkdir -p "$TMP_ACTION_PINS/bin"
cat > "$TMP_ACTION_PINS/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url="${*: -1}"
sha="${url##*/}"
[[ "$sha" != 0000000000000000000000000000000000000000 ]] || exit 22
printf '{"sha":"%s"}\n' "$sha"
EOF
chmod +x "$TMP_ACTION_PINS/bin/curl"

action_pin_output="$(
    CURL_BIN="$TMP_ACTION_PINS/bin/curl" \
        bash "$CI_VERIFY_GITHUB_ACTION_PINS_SCRIPT_PATH" "$GITHUB_IMAGE_ANALYSIS_PATH"
)"
assert_contains "$action_pin_output" 'Verified 3 GitHub Action commit pins'

sed 's/7188fc363630916deb702c7fdcf4e481b751f97a/0000000000000000000000000000000000000000/' \
    "$GITHUB_IMAGE_ANALYSIS_PATH" > "$TMP_ACTION_PINS/invalid.yml"
set +e
CURL_BIN="$TMP_ACTION_PINS/bin/curl" \
    bash "$CI_VERIFY_GITHUB_ACTION_PINS_SCRIPT_PATH" \
        "$TMP_ACTION_PINS/invalid.yml" >/dev/null 2>&1
action_pin_exit=$?
set -e
[[ "$action_pin_exit" -eq 1 ]] || {
    echo "Expected an unresolvable GitHub Action pin to exit 1, got $action_pin_exit." >&2
    exit 1
}

ruby - "$SEMAPHORE_PATH" "$SEMAPHORE_PUBLISH_PATH" <<'RUBY'
require "yaml"

build_config = YAML.load_file(ARGV.fetch(0))
publish_config = YAML.load_file(ARGV.fetch(1))
build_blocks = build_config.fetch("blocks")
publish_blocks = publish_config.fetch("blocks")
smoke = build_blocks.find { |block| block["name"] == "build image" } or abort "Missing build image block"
preflight = build_blocks.find { |block| block["name"] == "verify release source" } or abort "Missing verify release source block"
publish = publish_blocks.find { |block| block["name"] == "publish image" } or abort "Missing publish image block"
scan = publish_blocks.find { |block| block["name"] == "scan published image" } or abort "Missing scan published image block"

abort "Root pipeline must have build and preflight blocks" unless build_blocks.size == 2
abort "Global prologue must run checkout" unless build_config.fetch("global_job_config").fetch("prologue").fetch("commands") == ["checkout"]
abort "Build image block should not define empty dependencies" if smoke.key?("dependencies")
abort "Build image block must run only for PRs and latest" unless smoke.fetch("run").fetch("when") == "pull_request =~ '^.+$' OR branch = 'latest'"
abort "Build image block must not receive secrets" if smoke.fetch("task", {}).key?("secrets")
abort "Build image block must set build mode" unless smoke.fetch("task").fetch("env_vars").any? { |env| env["name"] == "CI_DOCKER_MODE" && env["value"] == "build" }
abort "Preflight block must run for release sources" unless preflight.fetch("run").fetch("when") == "pull_request !~ '^.+$' AND (branch =~ '^php[0-9][0-9]$' OR tag =~ '^[0-9]+[.][0-9]+([.][0-9]+)?$')"
abort "Preflight block must not receive secrets" if preflight.fetch("task", {}).key?("secrets")
abort "Preflight block must set preflight mode" unless preflight.fetch("task").fetch("env_vars").any? { |env| env["name"] == "CI_DOCKER_MODE" && env["value"] == "preflight" }
promotion = build_config.fetch("promotions").find { |item| item["name"] == "publish final image" } or abort "Missing publish final image promotion"
abort "Publish promotion must target publish.yml" unless promotion["pipeline_file"] == "publish.yml"
unless promotion.fetch("auto_promote").fetch("when") == "result = 'passed' AND pull_request !~ '^.+$' AND tag =~ '^[0-9]+[.][0-9]+([.][0-9]+)?$'"
    abort "Publish promotion must only run after passed version tags"
end
abort "Publish image block must explicitly define no dependencies" unless publish.fetch("dependencies") == []
abort "Publish image block must set publish mode" unless publish.fetch("task").fetch("env_vars").any? { |env| env["name"] == "CI_DOCKER_MODE" && env["value"] == "build-publish" }
publish_commands = publish.fetch("task").fetch("jobs").fetch(0).fetch("commands")
abort "Every publish job command must be a string" unless publish_commands.all? { |command| command.is_a?(String) }
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

for module_path in "$RELEASE_REF_PATH" "$IMAGE_CONTRACT_PATH" "$GIT_WORKTREE_PATH"; do
    [[ -f "$module_path" ]] || {
        echo "Missing maintenance module: $module_path" >&2
        exit 1
    }
done

# shellcheck disable=SC2030
release_ref_result="$(
    export CI_GIT_BRANCH=php85 CI_GIT_TAG='' CI_GIT_REF_TYPE=branch
    release_ref_resolve
    printf '%s|%s|%s|%s\n' "$RELEASE_REF_BRANCH" "$RELEASE_REF_TAG" "$RELEASE_REF_TYPE" "$RELEASE_REF_PUBLISH_TAG"
)"
[[ "$release_ref_result" == 'php85||branch|' ]] || {
    echo "Unexpected PHP branch classification: $release_ref_result" >&2
    exit 1
}

# shellcheck disable=SC2031
release_ref_result="$(
    export CI_GIT_BRANCH='' CI_GIT_TAG='' CI_GIT_REF_TYPE=''
    export GITHUB_REF_TYPE=tag GITHUB_REF_NAME=8.5.1
    release_ref_resolve
    printf '%s|%s|%s\n' "$RELEASE_REF_TAG" "$RELEASE_REF_TYPE" "$RELEASE_REF_PUBLISH_TAG"
)"
[[ "$release_ref_result" == '8.5.1|tag|8.5.1' ]] || {
    echo "Unexpected GitHub tag normalization: $release_ref_result" >&2
    exit 1
}

[[ "$(release_ref_branch_to_version php85)" == '8.5' ]] || {
    echo "Expected php85 to convert to tag 8.5" >&2
    exit 1
}

[[ "$(release_ref_version_to_branch 8.5.1)" == 'php85' ]] || {
    echo "Expected 8.5.1 to convert to branch php85" >&2
    exit 1
}

dockerfile_content="$(<"$DOCKERFILE_PATH")"
contract_missing="$(image_contract_missing_invariants "$dockerfile_content")"
[[ -z "$contract_missing" ]] || {
    echo "Maintained Dockerfile violates image contract:" >&2
    echo "$contract_missing" >&2
    exit 1
}

imagick_build_layer="$(
    awk '
        function inspect_instruction() {
            if (instruction ~ /^RUN / &&
                instruction ~ /\n        libmagickwand-dev;/ &&
                instruction ~ /docker-php-ext-install -j.* imagick/ &&
                instruction ~ /apt-get purge -y libmagickwand-dev/) {
                print instruction
            }
        }

        /^[[:upper:]][[:upper:]]*[[:space:]]/ {
            inspect_instruction()
            instruction = $0
            next
        }

        { instruction = instruction "\n" $0 }

        END { inspect_instruction() }
    ' "$DOCKERFILE_PATH"
)"
[[ -n "$imagick_build_layer" ]] || {
    echo "Expected imagick build dependencies, compilation, and purge in one RUN layer" >&2
    exit 1
}

broken_contract="${dockerfile_content/make install DESTDIR=\/tmp\/imgck/make install}"
contract_missing="$(image_contract_missing_invariants "$broken_contract")"
assert_contains "$contract_missing" 'make install DESTDIR=/tmp/imgck'

broken_contract="$dockerfile_content"$'\n        ffmpeg \\\n'
contract_missing="$(image_contract_missing_invariants "$broken_contract")"
assert_contains "$contract_missing" 'optional base package absent: ffmpeg'

broken_contract="${dockerfile_content/COPY --from=php-extension-installer \/usr\/bin\/install-php-extensions \/usr\/local\/bin\//}"
contract_missing="$(image_contract_missing_invariants "$broken_contract")"
assert_contains "$contract_missing" 'COPY --from=php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/'

assert_file_not_contains "$IMAGE_CONTRACT_PATH" 'gmp'
assert_file_not_contains "$AGENTS_PATH" 'GMP'
assert_file_not_contains "$DECISIONS_PATH" 'GMP'

buster_contract="${dockerfile_content/libwebp7/libwebp6}"
contract_missing="$(image_contract_missing_invariants "$buster_contract")"
[[ -z "$contract_missing" ]] || {
    echo "Debian Buster WebP runtime package should satisfy the image contract:" >&2
    echo "$contract_missing" >&2
    exit 1
}

broken_contract="${dockerfile_content/libwebp7/libwebp-runtime-missing}"
contract_missing="$(image_contract_missing_invariants "$broken_contract")"
assert_contains "$contract_missing" 'WebP runtime package: libwebp7 or libwebp6'

assert_file_contains "$SCRIPT_PATH" 'source "$ROOT_DIR/scripts/lib/git_worktree.sh"'
assert_file_contains "$SCRIPT_PATH" 'source "$ROOT_DIR/scripts/lib/image_contract.sh"'
assert_file_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'source "$ROOT_DIR/scripts/lib/release_ref.sh"'
assert_file_contains "$CI_TRIVY_SCAN_SCRIPT_PATH" 'source "$ROOT_DIR/scripts/lib/release_ref.sh"'
assert_file_contains "$TAGS_SCRIPT_PATH" 'source "$ROOT_DIR/scripts/lib/release_ref.sh"'
assert_file_contains "$TAGS_SCRIPT_PATH" '--approve-contract-change'
assert_file_contains "$SCRIPT_PATH" '--approve-contract-change'
assert_file_contains "$AGENTS_PATH" 'Never use `--approve-contract-change` unless the user'
assert_file_not_contains "$CI_DOCKER_BUILD_SCRIPT_PATH" 'trivy'

tooling_output="$(bash "$SCRIPT_PATH" verify-image-tooling latest)"
assert_contains "$tooling_output" "Image tooling branches:"
assert_contains "$tooling_output" "latest: ok"

legacy_tooling_output="$(bash "$SCRIPT_PATH" verify-image-tooling php73 php74 || true)"
assert_contains "$legacy_tooling_output" "php73"
assert_contains "$legacy_tooling_output" "php74"

test_temp_dir TMP_DOCKER_BIN ci-docker-bin
CI_DOCKER_LOG="$TMP_DOCKER_BIN/docker.log"
PR_PUBLISH_OUTPUT="$TMP_DOCKER_BIN/pr-publish.out"
TAG_PUBLISH_OUTPUT="$TMP_DOCKER_BIN/tag-publish.out"
export CI_DOCKER_LOG

default_image_ref="$DEFAULT_DOCKER_USERNAME/$DEFAULT_IMAGE_NAME"

install_docker_capture "$TMP_DOCKER_BIN"

feature_push_ci_output="$(PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_BRANCH=feature/test CI_GIT_REF_TYPE=branch bash "$CI_DOCKER_BUILD_SCRIPT_PATH")"
assert_contains "$feature_push_ci_output" 'Non-build ref: skipping Docker build'
if [[ -s "$CI_DOCKER_LOG" ]]; then
    echo "Expected ordinary feature branch push to avoid Docker commands." >&2
    exit 1
fi

build_only_ci_output="$(PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_BRANCH=latest bash "$CI_DOCKER_BUILD_SCRIPT_PATH")"
assert_file_contains "$CI_DOCKER_LOG" "docker build --pull --build-arg BUILDKIT_INLINE_CACHE=1 --cache-from $default_image_ref:$DEFAULT_BUILD_CACHE_TAG --cache-from $DEFAULT_BUILDER_IMAGE -f Dockerfile.ubuntu ."
assert_contains "$build_only_ci_output" 'Build-only branch: not publishing image'
assert_contains "$build_only_ci_output" 'Docker build completed in'
if grep -Fq -- "-t $DEFAULT_IMAGE_NAME:" "$CI_DOCKER_LOG"; then
    echo "Expected latest build-only CI run to avoid tagging the image." >&2
    exit 1
fi

: > "$CI_DOCKER_LOG"
pr_target_branch_output="$(PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_BRANCH=php85 CI_GIT_REF_TYPE=pull-request bash "$CI_DOCKER_BUILD_SCRIPT_PATH")"
assert_file_contains "$CI_DOCKER_LOG" "docker build --pull --build-arg BUILDKIT_INLINE_CACHE=1 --cache-from $default_image_ref:8.5 --cache-from $DEFAULT_BUILDER_IMAGE -f Dockerfile.ubuntu ."
assert_contains "$pr_target_branch_output" 'Build-only branch: not publishing image'
if grep -Fq -- "-t $DEFAULT_IMAGE_NAME:" "$CI_DOCKER_LOG"; then
    echo "Expected pull-request build-only CI run to avoid tagging the image." >&2
    exit 1
fi

: > "$CI_DOCKER_LOG"
php_branch_build_output="$(PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_BRANCH=php85 bash "$CI_DOCKER_BUILD_SCRIPT_PATH")"
assert_contains "$php_branch_build_output" 'Non-build ref: skipping Docker build'
if [[ -s "$CI_DOCKER_LOG" ]]; then
    echo "Expected PHP branch build mode to avoid all Docker commands." >&2
    exit 1
fi

: > "$CI_DOCKER_LOG"
branch_preflight_output="$(PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_BRANCH=php85 CI_DOCKER_MODE=preflight bash "$CI_DOCKER_BUILD_SCRIPT_PATH")"
assert_contains "$branch_preflight_output" 'Release source preflight passed: php85'
if [[ -s "$CI_DOCKER_LOG" ]]; then
    echo "Expected release preflight to avoid all Docker commands." >&2
    exit 1
fi

: > "$CI_DOCKER_LOG"
BUILD_METRICS_OUTPUT="$TMP_DOCKER_BIN/build-metrics.tsv"
tag_publish_output="$(PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_TAG=8.5 CI_GIT_REF_TYPE=tag CI_DOCKER_MODE=build-publish CI_BUILD_METRICS_FILE="$BUILD_METRICS_OUTPUT" DOCKER_PASSWORD=test bash "$CI_DOCKER_BUILD_SCRIPT_PATH")"
assert_file_contains "$CI_DOCKER_LOG" "docker build --pull --build-arg BUILDKIT_INLINE_CACHE=1 --cache-from $default_image_ref:8.5 --cache-from $DEFAULT_BUILDER_IMAGE -f Dockerfile.ubuntu -t $DEFAULT_IMAGE_NAME:8.5 ."
assert_file_contains "$CI_DOCKER_LOG" "docker login -u $DEFAULT_DOCKER_USERNAME --password-stdin"
assert_file_contains "$CI_DOCKER_LOG" "docker push $default_image_ref:8.5"
assert_contains "$tag_publish_output" 'Docker build completed in'
assert_file_contains "$BUILD_METRICS_OUTPUT" $'tag\tcache_prepare_seconds\tbuild_seconds\tpublish_seconds\ttotal_seconds\tcache_sources'
if ! awk -F '\t' -v expected_cache="$default_image_ref:8.5,$DEFAULT_BUILDER_IMAGE" '
    NR == 2 && $1 == "8.5" && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ \
        && $4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ && $6 == expected_cache { found = 1 }
    END { exit !found }
' "$BUILD_METRICS_OUTPUT"; then
    echo "Expected build metrics to contain numeric timings and cache sources." >&2
    exit 1
fi
if grep -Fq -- 'docker run --rm aquasec/trivy' "$CI_DOCKER_LOG"; then
    echo "Expected publish script not to run Trivy directly." >&2
    exit 1
fi

: > "$CI_DOCKER_LOG"
PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_TAG=8.5 CI_GIT_REF_TYPE=tag bash "$CI_TRIVY_SCAN_SCRIPT_PATH"
assert_file_contains "$CI_DOCKER_LOG" "docker run --rm aquasec/trivy:latest image --exit-code 0 --severity HIGH,CRITICAL $default_image_ref:8.5"

: > "$CI_DOCKER_LOG"
failed_scan_output="$(PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_TAG=8.5 CI_GIT_REF_TYPE=tag TRIVY_IMAGE=failing-trivy bash "$CI_TRIVY_SCAN_SCRIPT_PATH" 2>&1)"
assert_contains "$failed_scan_output" "Warning: non-blocking Trivy scan failed for $default_image_ref:8.5"
assert_file_contains "$CI_DOCKER_LOG" "docker run --rm failing-trivy image --exit-code 0 --severity HIGH,CRITICAL $default_image_ref:8.5"

: > "$CI_DOCKER_LOG"
patch_publish_output="$(PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_TAG=8.5.1 CI_GIT_REF_TYPE=tag CI_DOCKER_MODE=build-publish DOCKER_PASSWORD=test bash "$CI_DOCKER_BUILD_SCRIPT_PATH")"
assert_file_contains "$CI_DOCKER_LOG" "docker build --pull --build-arg BUILDKIT_INLINE_CACHE=1 --cache-from $default_image_ref:8.5.1 --cache-from $default_image_ref:8.5 --cache-from $DEFAULT_BUILDER_IMAGE -f Dockerfile.ubuntu -t $DEFAULT_IMAGE_NAME:8.5.1 ."
assert_contains "$patch_publish_output" 'Docker build completed in'

: > "$CI_DOCKER_LOG"
if PATH="$TMP_DOCKER_BIN:$PATH" CI_GIT_BRANCH=php85 CI_GIT_REF_TYPE=branch CI_DOCKER_MODE=build-publish DOCKER_PASSWORD=test bash "$CI_DOCKER_BUILD_SCRIPT_PATH" >"$TAG_PUBLISH_OUTPUT" 2>&1; then
    echo "Expected PHP branch build-publish mode to fail." >&2
    exit 1
fi
assert_file_contains "$TAG_PUBLISH_OUTPUT" 'Refusing to publish from non-version ref: php85.'

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

test_temp_dir TMP_REPO repo-sync-test
TMP_REPO_REMOTE="${TMP_REPO}-remote.git"
rm -rf "$TMP_REPO_REMOTE"
git init --bare "$TMP_REPO_REMOTE" >/dev/null 2>&1

for shared_file in "${SHARED_FILES[@]}"; do
    mkdir -p "$TMP_REPO/$(dirname "$shared_file")"
    cp "$ROOT_DIR/$shared_file" "$TMP_REPO/$shared_file"
done
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

    git remote add origin "$TMP_REPO_REMOTE"
    git push origin latest php85 >/dev/null 2>&1
    git tag 8.5 php85
    git push origin refs/tags/8.5 >/dev/null 2>&1

    printf '\nShared workflow update.\n' >>README.md
    git add README.md
    git -c commit.gpgsign=false commit -m "test shared update" >/dev/null

    if sync_push_drift_output="$(bash scripts/repo_sync.sh sync-shared --push php85 2>&1)"; then
        echo "Expected sync-shared --push to reject remaining shared-file drift." >&2
        exit 1
    fi
    assert_contains "$sync_push_drift_output" 'Refusing to push: shared-file drift remains.'

    sync_apply_output="$(bash scripts/repo_sync.sh sync-shared --apply php85)"
    assert_contains "$sync_apply_output" 'php85: committed shared-file sync.'
    sync_push_output="$(bash scripts/repo_sync.sh sync-shared --push php85)"
    assert_contains "$sync_push_output" 'Pushed shared-file sync branches atomically:'
    assert_contains "$sync_push_output" 'php85'
    [[ "$(git rev-parse php85)" == "$(git --git-dir="$TMP_REPO_REMOTE" rev-parse refs/heads/php85)" ]] || {
        echo "Expected sync-shared --push to update the remote php85 branch." >&2
        exit 1
    }
    assert_contains "$(git show php85:README.md)" 'Shared workflow update.'

    printf '\n# Test core image-contract policy change.\n' >>scripts/lib/image_contract.sh
    git add scripts/lib/image_contract.sh
    git -c commit.gpgsign=false commit -m "test contract policy update" >/dev/null
    sync_apply_output="$(bash scripts/repo_sync.sh sync-shared --apply php85)"
    assert_contains "$sync_apply_output" 'php85: committed shared-file sync.'
    if contract_push_output="$(bash scripts/repo_sync.sh sync-shared --push php85 2>&1)"; then
        echo "Expected sync-shared --push to require explicit approval for an image-contract policy change." >&2
        exit 1
    fi
    assert_contains "$contract_push_output" 'Core image-contract policy changed'
    contract_push_output="$(bash scripts/repo_sync.sh sync-shared --push --approve-contract-change php85)"
    assert_contains "$contract_push_output" 'Explicit core image-contract change approval supplied.'
    assert_contains "$contract_push_output" 'Pushed shared-file sync branches atomically:'

    if contract_tag_output="$(bash scripts/tags_update.sh --apply php85 2>&1)"; then
        echo "Expected tags_update.sh --apply to require explicit approval for an image-contract policy change." >&2
        exit 1
    fi
    assert_contains "$contract_tag_output" 'Core image-contract policy changed for php85 -> 8.5.'
    contract_tag_output="$(bash scripts/tags_update.sh --apply --approve-contract-change php85)"
    assert_contains "$contract_tag_output" 'Explicit core image-contract change approval supplied for php85 -> 8.5.'
    assert_contains "$contract_tag_output" 'Tag update complete.'

    if bash -c '
        set -euo pipefail
        source scripts/lib/git_worktree.sh
        trap git_worktree_transaction_cleanup EXIT
        git_worktree_transaction_begin "$PWD"
        git_worktree_transaction_create_branch php86 latest
        exit 42
    '; then
        echo "Expected failed worktree transaction fixture to fail." >&2
        exit 1
    fi
    if git show-ref --verify --quiet refs/heads/php86; then
        echo "Expected failed worktree transaction to remove its created branch." >&2
        exit 1
    fi
)

echo "repo_sync_test.sh: PASS"
