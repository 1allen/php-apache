#!/usr/bin/env bash

# Maintained Docker image contract. Validation output is one missing invariant
# per line; an empty result means the Dockerfile satisfies the contract.

image_contract_installer_source_present() {
    local dockerfile_content="$1"
    local image_ref

    # shellcheck disable=SC2016
    if [[ "$dockerfile_content" == *'FROM ${PHP_EXTENSION_INSTALLER_IMAGE} AS php-extension-installer'* ]] \
        && [[ "$dockerfile_content" == *"ARG PHP_EXTENSION_INSTALLER_IMAGE=$PHP_EXTENSION_INSTALLER_IMAGE"* ]]; then
        return 0
    fi

    for image_ref in "${PHP_EXTENSION_INSTALLER_IMAGE_REFS[@]}"; do
        [[ "$dockerfile_content" == *"FROM $image_ref AS php-extension-installer"* ]] && return 0
    done

    return 1
}

image_contract_missing_invariants() {
    local dockerfile_content="$1"
    local marker
    local package_name
    local package_line
    # shellcheck disable=SC2016
    local required_markers=(
        'COPY --from=php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/'
        'COPY --chown=$UID:$GID --from=imagemagick-builder /tmp/imgck/usr/local/ /usr/local/'
        'install-php-extensions gmp'
        'docker-php-ext-configure imagick --with-imagick=/usr/local'
        'PKG_CONFIG_PATH=/usr/local/lib/pkgconfig'
        'make install DESTDIR=/tmp/imgck'
        '--without-x'
        'ARG IMAGEMAGICK_SHA256='
        'ARG IMAGICK_SHA256='
        'imagemagick.tar.gz | sha256sum -c -'
        'imagick.tgz | sha256sum -c -'
        'https://github.com/ImageMagick/ImageMagick/archive/${IMAGEMAGICK_VERSION}.tar.gz'
        'https://pecl.php.net/get/imagick-${IMAGICK_VERSION}.tgz'
        'libwebp7'
        'libwebpdemux2'
        'libwebpmux3'
        'magick -size 2x2 xc:white /tmp/webp-contract.webp'
        'Imagick::queryFormats("WEBP")'
    )

    if ! image_contract_installer_source_present "$dockerfile_content"; then
        echo "php-extension-installer source from config/php-branches.conf"
    fi

    for marker in "${required_markers[@]}"; do
        [[ "$dockerfile_content" == *"$marker"* ]] || echo "$marker"
    done

    for package_name in jpegoptim mariadb-client webp ffmpeg libxt6; do
        package_line="        $package_name \\"
        if [[ "$dockerfile_content" == *"$package_line"* ]]; then
            echo "optional base package absent: $package_name"
        fi
    done

    return 0
}

image_contract_validate_content() {
    local dockerfile_content="$1"
    local missing

    missing="$(image_contract_missing_invariants "$dockerfile_content")"
    [[ -z "$missing" ]] || {
        printf '%s\n' "$missing"
        return 1
    }
}
