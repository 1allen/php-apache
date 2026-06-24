# Maintenance Runbook

This project maintains custom PHP Apache images derived from
`webdevops/php-apache`. The image adds a current ImageMagick build with WebP
support, PECL `imagick`, common media/database CLI tools, `gmp`, and the
`install-php-extensions` helper for downstream customization.

Upstream references:

- Docker Hub image:
  `https://hub.docker.com/r/webdevops/php-apache`
- Source repository:
  `https://github.com/webdevops/Dockerfile`
- mlocati PHP extension installer:
  `https://github.com/mlocati/docker-php-extension-installer`

## Current Image Decisions

As of 2026-06-24:

- `webdevops/php-apache:8.5` is the current Ubuntu base used by
  `Dockerfile.ubuntu`.
- ImageMagick is pinned to `7.1.2-26`.
- PECL `imagick` is pinned to `3.8.1`.
- `install-php-extensions` is copied from
  `ghcr.io/mlocati/php-extension-installer:latest` into `/usr/local/bin`.

## Why Imagick Is Manual

The final image needs `imagick` to build against the custom ImageMagick copied
from the `imagemagick-builder` stage into `/usr/local`. The mlocati installer
knows how to install `imagick`, but on Debian it also manages distro
ImageMagick packages. That is useful for default images, but it can hide whether
the extension linked to the custom `/usr/local` ImageMagick build.

For that reason:

- use `install-php-extensions` for ordinary extensions such as `gmp`,
  `protobuf`, `grpc`, and `redis`;
- keep PECL `imagick` installation explicit unless you verify the linked
  libraries with `ldd`;
- run `ldconfig /usr/local/lib` before and after compiling `imagick`.

Useful verification commands after a build:

```bash
docker run --rm php-apache:local php -m | grep -E '^(gmp|imagick)$'
docker run --rm php-apache:local php --ri imagick
docker run --rm php-apache:local sh -lc 'ldd "$(php-config --extension-dir)/imagick.so" | grep -i magick'
docker run --rm php-apache:local command -v install-php-extensions
```

## Updating Upstreams

Check these sources before changing pins:

- ImageMagick releases:
  `https://api.github.com/repos/ImageMagick/ImageMagick/releases/latest`
- PECL imagick:
  `https://pecl.php.net/rest/r/imagick/latest.txt`
- webdevops PHP Apache tags:
  `https://hub.docker.com/v2/namespaces/webdevops/repositories/php-apache/tags?page_size=100`
- mlocati installer supported extensions:
  `https://raw.githubusercontent.com/mlocati/docker-php-extension-installer/master/data/supported-extensions`

Example version check:

```bash
curl -fsSL https://api.github.com/repos/ImageMagick/ImageMagick/releases/latest \
  | jq -r '.tag_name'
curl -fsSL https://pecl.php.net/rest/r/imagick/latest.txt
curl -fsSL 'https://hub.docker.com/v2/namespaces/webdevops/repositories/php-apache/tags?page_size=100' \
  | jq -r '.results[].name' \
  | grep -E '^[0-9]+\.[0-9]+$'
```

After updating versions, run:

```bash
bash tests/repo_sync_test.sh
docker build --pull -f Dockerfile.ubuntu -t php-apache:local .
```

If the local Docker build is not practical, still run the shell test and review
the Dockerfile diff carefully. The real build happens in Semaphore.

## Downstream Images

Downstream images based on these project images can install more PHP extensions
without downloading the installer again:

```Dockerfile
FROM 1allen/php-apache:8.5

RUN install-php-extensions protobuf grpc redis
```

This replaces the older local PECL customization pattern:

```Dockerfile
FROM 1allen/php-apache:8.5

RUN apt-get update && apt-get install -y zlib1g-dev \
    && pecl install grpc \
    && pecl install redis
RUN docker-php-ext-enable grpc redis
```

With the bundled installer, the same intent becomes:

```Dockerfile
FROM 1allen/php-apache:8.5

RUN install-php-extensions grpc redis protobuf
```

The installer resolves build packages, installs the PECL-backed extensions, and
enables them. Use this for downstream `grpc`, `redis`, and `protobuf` unless
you are debugging a PECL-specific failure and need to reproduce the manual
steps.

Pin extension versions downstream when reproducibility matters:

```Dockerfile
FROM 1allen/php-apache:8.5

RUN install-php-extensions protobuf-4.30.2 grpc-1.72.0 redis-6.2.0
```

Use the installer for extension dependencies, but keep application packages in
the downstream Dockerfile so this base image stays broadly reusable.

## Branch Flow

1. Make shared changes on `latest`.
2. Confirm shared files are listed in `config/php-branches.conf`.
3. Preview branch drift:

   ```bash
   bash scripts/repo_sync.sh sync-shared
   ```

4. Apply branch-local sync commits:

   ```bash
   bash scripts/repo_sync.sh sync-shared --apply
   ```

5. Push the updated PHP branches so Semaphore builds branch-specific image tags.
6. Preview and apply Docker tag updates when needed:

   ```bash
   bash scripts/tags_update.sh
   bash scripts/tags_update.sh --apply
   ```
