#!/usr/bin/env bash

# Report or wait for the publish-pipeline status of version-like Git refs.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/php-branches.conf"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/release_ref.sh"

GH_BIN="${GH_BIN:-gh}"
JQ_BIN="${JQ_BIN:-jq}"
RELEASE_STATUS_CONTEXT="${RELEASE_STATUS_CONTEXT:-ci/semaphoreci/tag: php-apache build pipeline}"
WAIT_FOR_COMPLETION=false
POLL_INTERVAL_SECONDS=30
TIMEOUT_SECONDS=1800
REFS=()

usage() {
    cat <<'EOF'
Usage:
  bash scripts/ci/release_status.sh [--wait] [--interval SECONDS] [--timeout SECONDS] [ref...]

Reports the current publish-pipeline status for the supplied Git refs. Without
refs, checks the configured supported PHP version tags. Use --wait to poll until
all releases succeed, one fails, or the timeout expires.

Exit codes:
  0  all release pipelines succeeded
  1  at least one release pipeline failed
  2  a release is pending/missing, or --wait timed out
  3  status lookup or local configuration failed
EOF
}

require_nonnegative_integer() {
    local option_name="$1"
    local value="$2"

    [[ "$value" =~ ^[0-9]+$ ]] || {
        echo "$option_name requires a non-negative integer, got: $value" >&2
        exit 3
    }
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wait)
            WAIT_FOR_COMPLETION=true
            shift
            ;;
        --interval)
            [[ $# -ge 2 ]] || { echo "--interval requires a value." >&2; exit 3; }
            POLL_INTERVAL_SECONDS="$2"
            require_nonnegative_integer --interval "$POLL_INTERVAL_SECONDS"
            shift 2
            ;;
        --timeout)
            [[ $# -ge 2 ]] || { echo "--timeout requires a value." >&2; exit 3; }
            TIMEOUT_SECONDS="$2"
            require_nonnegative_integer --timeout "$TIMEOUT_SECONDS"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            REFS+=("$@")
            break
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 3
            ;;
        *)
            REFS+=("$1")
            shift
            ;;
    esac
done

if [[ ${#REFS[@]} -eq 0 ]]; then
    for branch in "${SUPPORTED_PHP_BRANCHES[@]}"; do
        REFS+=("$(release_ref_branch_to_version "$branch")")
    done
fi

command -v "$GH_BIN" >/dev/null 2>&1 || {
    echo "Missing GitHub CLI: $GH_BIN" >&2
    exit 3
}
command -v "$JQ_BIN" >/dev/null 2>&1 || {
    echo "Missing jq: $JQ_BIN" >&2
    exit 3
}

REPOSITORY="${GITHUB_REPOSITORY:-}"
if [[ -z "$REPOSITORY" ]]; then
    REPOSITORY="$($GH_BIN repo view --json nameWithOwner --jq .nameWithOwner)" || {
        echo "Unable to resolve the GitHub repository." >&2
        exit 3
    }
fi

check_release_statuses() {
    local ref
    local sha
    local payload
    local row
    local state
    local target_url
    local pending=false
    local failed=false

    for ref in "${REFS[@]}"; do
        sha="$(git -C "$ROOT_DIR" rev-parse "$ref^{commit}" 2>/dev/null)" || {
            echo "Unable to resolve Git ref: $ref" >&2
            return 3
        }
        payload="$($GH_BIN api "repos/$REPOSITORY/commits/$sha/status")" || {
            echo "Unable to read release status for $ref ($sha)." >&2
            return 3
        }
        # shellcheck disable=SC2016
        row="$(
            "$JQ_BIN" -r --arg context "$RELEASE_STATUS_CONTEXT" '
                [.statuses[] | select(.context == $context)][0]
                | if . == null then ["missing", ""]
                  else [.state, (.target_url // "")]
                  end
                | @tsv
            ' <<<"$payload"
        )"
        IFS=$'\t' read -r state target_url <<<"$row"
        printf '%s\t%s\t%s\n' "$ref" "$state" "$target_url"

        case "$state" in
            success)
                ;;
            failure|error)
                failed=true
                ;;
            *)
                pending=true
                ;;
        esac
    done

    [[ "$failed" == false ]] || return 1
    [[ "$pending" == false ]] || return 2
    return 0
}

started_at="$(date +%s)"
while true; do
    if check_release_statuses; then
        exit 0
    else
        status=$?
    fi

    [[ "$status" -ne 1 && "$status" -ne 3 ]] || exit "$status"
    [[ "$WAIT_FOR_COMPLETION" == true ]] || exit 2

    now="$(date +%s)"
    if (( now - started_at >= TIMEOUT_SECONDS )); then
        echo "Timed out after ${TIMEOUT_SECONDS}s waiting for release pipelines." >&2
        exit 2
    fi
    sleep "$POLL_INTERVAL_SECONDS"
done
