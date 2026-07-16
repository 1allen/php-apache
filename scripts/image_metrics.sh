#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/php-branches.conf"

DOCKER_USERNAME="${DOCKER_USERNAME:-$DEFAULT_DOCKER_USERNAME}"
IMAGE_NAME="${IMAGE_NAME:-$DEFAULT_IMAGE_NAME}"
DOCKER_HUB_API_BASE="${DOCKER_HUB_API_BASE:-https://hub.docker.com/v2/repositories}"
BASELINE_FILE="${BASELINE_FILE:-$ROOT_DIR/config/image-size-baseline.tsv}"
BUILD_METRICS_FILE=""
OUTPUT_FORMAT="markdown"
target_tags=()

usage() {
    cat <<'EOF'
Usage:
  bash scripts/image_metrics.sh [--format markdown|tsv] [--baseline FILE]
                                [--build-metrics FILE] [tag...]

Reports the current compressed linux/amd64 size from Docker Hub and compares it
with the recorded baseline. Supported phpXX tags are reported by default.

Environment overrides:
  DOCKER_USERNAME       Docker Hub namespace
  IMAGE_NAME            Docker Hub repository
  DOCKER_HUB_API_BASE   Docker Hub API root (useful for deterministic tests)
  BASELINE_FILE         Baseline TSV path
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

baseline_for_tag() {
    local tag="$1"

    awk -F '\t' -v tag="$tag" '
        NR > 1 && $1 == tag {
            print $2 "\t" $3 "\t" $4
            found = 1
            exit
        }
        END {
            if (!found) {
                exit 1
            }
        }
    ' "$BASELINE_FILE"
}

build_metrics_for_tag() {
    local tag="$1"

    awk -F '\t' -v tag="$tag" '
        NR > 1 && $1 == tag && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ \
            && $4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ {
            print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6
            found = 1
            exit
        }
        END {
            if (!found) {
                exit 1
            }
        }
    ' "$BUILD_METRICS_FILE"
}

fetch_tag_metrics() {
    local tag="$1"
    local tag_url
    local response

    tag_url="$DOCKER_HUB_API_BASE/$DOCKER_USERNAME/$IMAGE_NAME/tags/$tag"
    response="$(curl -fsSL --retry 3 --retry-connrefused --connect-timeout 15 "$tag_url")" \
        || die "Unable to read Docker Hub metadata for $DOCKER_USERNAME/$IMAGE_NAME:$tag"

    jq -er '
        [
            .digest,
            ([.images[]? | select(.architecture == "amd64" and .os == "linux") | .size] | first)
        ]
        | select(.[0] != null and .[1] != null)
        | @tsv
    ' <<<"$response" \
        || die "Missing linux/amd64 digest or size for $DOCKER_USERNAME/$IMAGE_NAME:$tag"
}

format_mib() {
    awk -v bytes="$1" 'BEGIN { printf "%.1f MiB", bytes / 1048576 }'
}

format_seconds() {
    if [[ "$1" == "-" ]]; then
        printf 'n/a'
    else
        printf '%ss' "$1"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --format)
            [[ $# -ge 2 ]] || die "--format requires markdown or tsv"
            OUTPUT_FORMAT="$2"
            shift
            ;;
        --baseline)
            [[ $# -ge 2 ]] || die "--baseline requires a file"
            BASELINE_FILE="$2"
            shift
            ;;
        --build-metrics)
            [[ $# -ge 2 ]] || die "--build-metrics requires a file"
            BUILD_METRICS_FILE="$2"
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
            target_tags+=("$1")
            ;;
    esac
    shift
done

[[ "$OUTPUT_FORMAT" == "markdown" || "$OUTPUT_FORMAT" == "tsv" ]] \
    || die "Unsupported output format: $OUTPUT_FORMAT"
[[ -r "$BASELINE_FILE" ]] || die "Baseline file is not readable: $BASELINE_FILE"
if [[ -n "$BUILD_METRICS_FILE" ]]; then
    [[ -r "$BUILD_METRICS_FILE" ]] || die "Build metrics file is not readable: $BUILD_METRICS_FILE"
    expected_build_metrics_header=$'tag\tcache_prepare_seconds\tbuild_seconds\tpublish_seconds\ttotal_seconds\tcache_sources'
    IFS= read -r build_metrics_header <"$BUILD_METRICS_FILE"
    [[ "$build_metrics_header" == "$expected_build_metrics_header" ]] \
        || die "Unsupported build metrics header: $build_metrics_header"
fi

require_command curl
require_command jq
require_command awk

if [[ ${#target_tags[@]} -eq 0 ]]; then
    if [[ -n "$BUILD_METRICS_FILE" ]]; then
        while IFS= read -r tag; do
            [[ -n "$tag" ]] && target_tags+=("$tag")
        done < <(awk -F '\t' 'NR > 1 { print $1 }' "$BUILD_METRICS_FILE")
    else
        target_tags=("${SUPPORTED_PHP_BRANCHES[@]}")
    fi
fi

[[ ${#target_tags[@]} -gt 0 ]] || die "No image tags to report."

if [[ "$OUTPUT_FORMAT" == "markdown" ]]; then
    if [[ -n "$BUILD_METRICS_FILE" ]]; then
        echo "| Tag | Cache prep | Build | Publish | Total | Baseline | Current | Saved | Saved % | Current digest | Cache sources |"
        echo "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |"
    else
        echo "| Tag | Baseline | Current | Saved | Saved % | Current digest |"
        echo "| --- | ---: | ---: | ---: | ---: | --- |"
    fi
else
    if [[ -n "$BUILD_METRICS_FILE" ]]; then
        printf 'tag\tcache_prepare_seconds\tbuild_seconds\tpublish_seconds\ttotal_seconds\tbaseline_bytes\tcurrent_bytes\tsaved_bytes\tsaved_percent\tcurrent_digest\tbaseline_digest\tbaseline_tag_last_updated\tcache_sources\n'
    else
        printf 'tag\tbaseline_bytes\tcurrent_bytes\tsaved_bytes\tsaved_percent\tcurrent_digest\tbaseline_digest\tbaseline_tag_last_updated\n'
    fi
fi

total_baseline_bytes=0
total_current_bytes=0
comparable_tags=0

for tag in "${target_tags[@]}"; do
    [[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid Docker tag: $tag"

    current_metrics="$(fetch_tag_metrics "$tag")"
    IFS=$'\t' read -r current_digest current_bytes <<<"$current_metrics"

    baseline_digest="-"
    baseline_bytes="-"
    baseline_tag_last_updated="-"
    saved_bytes="-"
    saved_percent="-"
    cache_prepare_seconds="-"
    build_seconds="-"
    publish_seconds="-"
    total_seconds="-"
    cache_sources="-"

    if [[ -n "$BUILD_METRICS_FILE" ]]; then
        build_metrics="$(build_metrics_for_tag "$tag" 2>/dev/null)" \
            || die "Missing valid build metrics for tag: $tag"
        IFS=$'\t' read -r cache_prepare_seconds build_seconds publish_seconds total_seconds cache_sources <<<"$build_metrics"
    fi

    if baseline="$(baseline_for_tag "$tag" 2>/dev/null)"; then
        IFS=$'\t' read -r baseline_digest baseline_bytes baseline_tag_last_updated <<<"$baseline"
        saved_bytes=$((baseline_bytes - current_bytes))
        saved_percent="$(awk -v saved="$saved_bytes" -v baseline="$baseline_bytes" \
            'BEGIN { printf "%.2f", (saved / baseline) * 100 }')"
        total_baseline_bytes=$((total_baseline_bytes + baseline_bytes))
        total_current_bytes=$((total_current_bytes + current_bytes))
        comparable_tags=$((comparable_tags + 1))
    fi

    if [[ "$OUTPUT_FORMAT" == "markdown" ]]; then
        if [[ -n "$BUILD_METRICS_FILE" && "$baseline_bytes" == "-" ]]; then
            printf '| %s | %s | %s | %s | %s | n/a | %s | n/a | n/a | %s | %s |\n' \
                "$tag" "$(format_seconds "$cache_prepare_seconds")" \
                "$(format_seconds "$build_seconds")" "$(format_seconds "$publish_seconds")" \
                "$(format_seconds "$total_seconds")" "$(format_mib "$current_bytes")" \
                "$current_digest" "${cache_sources//,/, }"
        elif [[ -n "$BUILD_METRICS_FILE" ]]; then
            printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s%% | %s | %s |\n' \
                "$tag" "$(format_seconds "$cache_prepare_seconds")" \
                "$(format_seconds "$build_seconds")" "$(format_seconds "$publish_seconds")" \
                "$(format_seconds "$total_seconds")" "$(format_mib "$baseline_bytes")" \
                "$(format_mib "$current_bytes")" "$(format_mib "$saved_bytes")" \
                "$saved_percent" "$current_digest" "${cache_sources//,/, }"
        elif [[ "$baseline_bytes" == "-" ]]; then
            printf '| %s | n/a | %s | n/a | n/a | %s |\n' \
                "$tag" "$(format_mib "$current_bytes")" "$current_digest"
        else
            printf '| %s | %s | %s | %s | %s%% | %s |\n' \
                "$tag" \
                "$(format_mib "$baseline_bytes")" \
                "$(format_mib "$current_bytes")" \
                "$(format_mib "$saved_bytes")" \
                "$saved_percent" \
                "$current_digest"
        fi
    else
        if [[ -n "$BUILD_METRICS_FILE" ]]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$tag" "$cache_prepare_seconds" "$build_seconds" "$publish_seconds" \
                "$total_seconds" "$baseline_bytes" "$current_bytes" "$saved_bytes" \
                "$saved_percent" "$current_digest" "$baseline_digest" \
                "$baseline_tag_last_updated" "$cache_sources"
        else
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$tag" "$baseline_bytes" "$current_bytes" "$saved_bytes" \
                "$saved_percent" "$current_digest" "$baseline_digest" "$baseline_tag_last_updated"
        fi
    fi
done

if [[ $comparable_tags -gt 0 ]]; then
    total_saved_bytes=$((total_baseline_bytes - total_current_bytes))
    total_saved_percent="$(awk -v saved="$total_saved_bytes" -v baseline="$total_baseline_bytes" \
        'BEGIN { printf "%.2f", (saved / baseline) * 100 }')"
    total_tag_label="tags"
    [[ $comparable_tags -eq 1 ]] && total_tag_label="tag"

    if [[ "$OUTPUT_FORMAT" == "markdown" && -n "$BUILD_METRICS_FILE" ]]; then
        printf '| **Total (%s %s)** | - | - | - | - | **%s** | **%s** | **%s** | **%s%%** | - | - |\n' \
            "$comparable_tags" "$total_tag_label" \
            "$(format_mib "$total_baseline_bytes")" \
            "$(format_mib "$total_current_bytes")" \
            "$(format_mib "$total_saved_bytes")" \
            "$total_saved_percent"
    elif [[ "$OUTPUT_FORMAT" == "markdown" ]]; then
        printf '| **Total (%s %s)** | **%s** | **%s** | **%s** | **%s%%** | - |\n' \
            "$comparable_tags" "$total_tag_label" \
            "$(format_mib "$total_baseline_bytes")" \
            "$(format_mib "$total_current_bytes")" \
            "$(format_mib "$total_saved_bytes")" \
            "$total_saved_percent"
    elif [[ -n "$BUILD_METRICS_FILE" ]]; then
        printf 'TOTAL\t-\t-\t-\t-\t%s\t%s\t%s\t%s\t-\t-\t-\t-\n' \
            "$total_baseline_bytes" "$total_current_bytes" "$total_saved_bytes" \
            "$total_saved_percent"
    else
        printf 'TOTAL\t%s\t%s\t%s\t%s\t-\t-\t-\n' \
            "$total_baseline_bytes" "$total_current_bytes" "$total_saved_bytes" \
            "$total_saved_percent"
    fi
fi
