#!/usr/bin/env bash

TEST_TEMP_PATHS=()

test_cleanup() {
    local path

    for path in "${TEST_TEMP_PATHS[@]+"${TEST_TEMP_PATHS[@]}"}"; do
        [[ -e "$path" ]] && rm -rf "$path"
    done
}

trap test_cleanup EXIT

test_temp_dir() {
    local variable_name="$1"
    local prefix="${2:-php-apache-test}"
    local path

    path="$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")"
    TEST_TEMP_PATHS+=("$path")
    printf -v "$variable_name" '%s' "$path"
}

assert_contains() {
    local haystack="$1"
    local needle="$2"

    [[ "$haystack" == *"$needle"* ]] || {
        echo "Expected output to contain: $needle" >&2
        exit 1
    }
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"

    [[ "$haystack" != *"$needle"* ]] || {
        echo "Expected output not to contain: $needle" >&2
        exit 1
    }
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

install_docker_capture() {
    local bin_dir="$1"

    mkdir -p "$bin_dir"
    cat > "$bin_dir/docker" <<'EOF'
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
    chmod +x "$bin_dir/docker"
}
