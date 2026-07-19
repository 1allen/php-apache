#!/usr/bin/env bash

# Verify that every remote GitHub Action in the supplied workflows is pinned to
# a full commit SHA and that GitHub resolves that commit in the action's repo.

set -euo pipefail

CURL_BIN="${CURL_BIN:-curl}"

die() {
    echo "Error: $*" >&2
    exit 1
}

[[ $# -gt 0 ]] || die "Usage: bash scripts/ci/verify_github_action_pins.sh WORKFLOW [...]"
command -v "$CURL_BIN" >/dev/null 2>&1 || die "Required command not found: $CURL_BIN"

curl_args=(
    -fsSL
    --retry 2
    --retry-connrefused
    --connect-timeout 15
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
)
if [[ -n "${GH_TOKEN:-}" ]]; then
    curl_args+=(-H "Authorization: Bearer $GH_TOKEN")
fi

pin_count=0
for workflow_path in "$@"; do
    [[ -f "$workflow_path" ]] || die "Workflow not found: $workflow_path"

    while IFS= read -r action_ref; do
        [[ -n "$action_ref" ]] || continue
        [[ "$action_ref" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(/[A-Za-z0-9_./-]+)?@([0-9a-f]{40})$ ]] \
            || die "GitHub Action must use a full commit pin: $action_ref"

        action_repository="${BASH_REMATCH[1]}"
        action_sha="${BASH_REMATCH[3]}"
        "$CURL_BIN" "${curl_args[@]}" -o /dev/null \
            "https://api.github.com/repos/$action_repository/commits/$action_sha" \
            || die "GitHub does not resolve action pin: $action_ref"

        echo "Resolved GitHub Action pin: $action_ref"
        pin_count=$((pin_count + 1))
    done < <(
        sed -nE 's/^[[:space:]]*uses:[[:space:]]*([^[:space:]#]+).*$/\1/p' \
            "$workflow_path"
    )
done

[[ "$pin_count" -gt 0 ]] || die "No GitHub Action references found"
echo "Verified $pin_count GitHub Action commit pins"
