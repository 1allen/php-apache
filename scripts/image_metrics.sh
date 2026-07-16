#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/php-branches.conf"

DOCKER_USERNAME="${DOCKER_USERNAME:-$DEFAULT_DOCKER_USERNAME}"
IMAGE_NAME="${IMAGE_NAME:-$DEFAULT_IMAGE_NAME}"
DOCKER_HUB_API_BASE="${DOCKER_HUB_API_BASE:-https://hub.docker.com/v2/repositories}"
BASELINE_FILE="${BASELINE_FILE:-$ROOT_DIR/config/image-size-baseline.tsv}"
OUTPUT_FORMAT="markdown"
target_tags=()

usage() {
    cat <<'EOF'
Usage:
  bash scripts/image_metrics.sh [--format markdown|tsv] [--baseline FILE] [tag...]

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

require_command curl
require_command jq
require_command awk

if [[ ${#target_tags[@]} -eq 0 ]]; then
    target_tags=("${SUPPORTED_PHP_BRANCHES[@]}")
fi

if [[ "$OUTPUT_FORMAT" == "markdown" ]]; then
    echo "| Tag | Baseline | Current | Saved | Saved % | Current digest |"
    echo "| --- | ---: | ---: | ---: | ---: | --- |"
else
    printf 'tag\tbaseline_bytes\tcurrent_bytes\tsaved_bytes\tsaved_percent\tcurrent_digest\tbaseline_digest\tbaseline_tag_last_updated\n'
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
        if [[ "$baseline_bytes" == "-" ]]; then
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
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$tag" "$baseline_bytes" "$current_bytes" "$saved_bytes" \
            "$saved_percent" "$current_digest" "$baseline_digest" "$baseline_tag_last_updated"
    fi
done

if [[ $comparable_tags -gt 0 ]]; then
    total_saved_bytes=$((total_baseline_bytes - total_current_bytes))
    total_saved_percent="$(awk -v saved="$total_saved_bytes" -v baseline="$total_baseline_bytes" \
        'BEGIN { printf "%.2f", (saved / baseline) * 100 }')"
    total_tag_label="tags"
    [[ $comparable_tags -eq 1 ]] && total_tag_label="tag"

    if [[ "$OUTPUT_FORMAT" == "markdown" ]]; then
        printf '| **Total (%s %s)** | **%s** | **%s** | **%s** | **%s%%** | - |\n' \
            "$comparable_tags" "$total_tag_label" \
            "$(format_mib "$total_baseline_bytes")" \
            "$(format_mib "$total_current_bytes")" \
            "$(format_mib "$total_saved_bytes")" \
            "$total_saved_percent"
    else
        printf 'TOTAL\t%s\t%s\t%s\t%s\t-\t-\t-\n' \
            "$total_baseline_bytes" "$total_current_bytes" "$total_saved_bytes" \
            "$total_saved_percent"
    fi
fi
