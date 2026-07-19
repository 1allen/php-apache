# php-apache

Custom [`webdevops/php-apache`](https://hub.docker.com/r/webdevops/php-apache)
images with a newer pinned ImageMagick, bundled PECL `imagick` linked against
that build, and verified WebP support.

## Features

- newer pinned ImageMagick built under `/usr/local`, with verified WebP support
- pinned PECL `imagick` compiled against that custom ImageMagick build
- `install-php-extensions` available for downstream image customization

## Useful Build Improvements

- SHA-256 verification for downloaded ImageMagick and PECL `imagick` sources
- a headless ImageMagick build without X11, documentation, C++ bindings, static
  archives, or libtool metadata
- explicit WebP runtime libraries without bundling the standalone `webp` CLI
- build-time WebP checks through both ImageMagick and PHP `imagick`
- compatibility cleanup for an inherited ionCube configuration only when its
  loader is missing or unusable

## Supported Images

Published images are available from
[`1allen/php-apache` on Docker Hub](https://hub.docker.com/r/1allen/php-apache).
The maintained PHP lines are:

| PHP | Image |
| --- | --- |
| 8.0 | `1allen/php-apache:8.0` |
| 8.1 | `1allen/php-apache:8.1` |
| 8.2 | `1allen/php-apache:8.2` |
| 8.3 | `1allen/php-apache:8.3` |
| 8.4 | `1allen/php-apache:8.4` |
| 8.5 | `1allen/php-apache:8.5` |

PHP 7.3 and 7.4 images are deprecated and frozen. New projects should use a
supported PHP 8 image.

Compare current Docker Hub compressed sizes with the recorded pre-cleanup
baseline:

```bash
bash scripts/image_metrics.sh
```

See `docs/maintenance.md` for metric semantics and machine-readable output.

## Quick Start

Mount an application at `/app`, expose Apache on port 8080, and set the web
document root explicitly:

```bash
docker run --rm \
  --publish 8080:80 \
  --env WEB_DOCUMENT_ROOT=/app \
  --volume "$PWD:/app" \
  1allen/php-apache:8.5
```

Then open `http://localhost:8080`. Adapt the image tag, mount path, and document
root to the application.

## Downstream Customization

Application-specific PHP extensions and command-line tools stay downstream.
The final image includes `install-php-extensions`, so a derived image can
install only what the application uses:

```Dockerfile
FROM 1allen/php-apache:8.5

RUN set -eux; \
    install-php-extensions protobuf grpc redis; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        jpegoptim \
        webp \
        ffmpeg \
        mariadb-client; \
    rm -rf /var/lib/apt/lists/*
```

`jpegoptim` and `webp` are image-optimization CLIs, `ffmpeg` is media tooling,
and `mariadb-client` provides database administration commands. Remove
unneeded lines from the example: fewer runtime packages have a larger impact
than compressing commands into one layer. `--no-install-recommends` avoids
optional dependency trees, and deleting `/var/lib/apt/lists` in the same layer
keeps package indexes out of the resulting image.

Pin extension versions when reproducible builds require them. The bundled
`imagick` extension should remain unchanged because it is intentionally compiled
against this image's custom ImageMagick. WebP support in bundled
ImageMagick/imagick is part of the base contract and does not depend on the
optional `webp` CLI.

## Rootless Docker

Use the same image with an explicit runtime override when bind-mounted files
must remain owned by the user running a rootless Docker daemon:

```yaml
services:
  php:
    image: 1allen/php-apache:8.5
    user: "0:0"
    environment:
      CONTAINER_UID: "0"
      SERVICE_PHPFPM_OPTS: "-R"
      WEB_DOCUMENT_ROOT: /app
    volumes:
      - .:/app
```

This mode is only for a verified rootless Docker daemon. Do not copy it into a
rootful Docker configuration. See
[Rootless Docker bind mounts](docs/maintenance.md#rootless-docker-bind-mounts)
for the ownership model, safety warning, and verification steps.

## Repository Development

The `latest` branch is the integration branch for shared maintenance work; it
is not a consumer image tag. PHP branches hold version-specific Dockerfiles but
do not publish branch-named images. Published PHP images come only from version-like Git tags.
Shared maintenance commits do not require rebuilding or moving these tags;
publish a new image revision only when release image inputs change or an
explicit rebuild is intended.

Run the required checks for a change on `latest`:

```bash
bash tests/repo_sync_test.sh
bash scripts/repo_sync.sh verify-image-tooling latest
```

After equivalent Dockerfile behavior has been applied to all supported PHP
branches, verify the complete supported set:

```bash
bash scripts/repo_sync.sh verify-image-tooling
```

Shared-file propagation and its remote push are separate gated phases:

```bash
bash scripts/repo_sync.sh sync-shared --apply
# Run the required checks before changing remote branches.
bash scripts/repo_sync.sh sync-shared --push
```

After moving supported version tags, check once or wait for every publish
pipeline to finish:

```bash
bash scripts/ci/release_status.sh
bash scripts/ci/release_status.sh --wait
```

Use `bash scripts/docker_hub_cleanup.sh` to audit retired branch-named and
floating Docker Hub tags. Its explicit `--apply` mode deletes only the
policy-derived retired set and verifies the result. When the Docker Hub
deletion PAT is stored in GitHub, use the documented
manual GitHub Actions cleanup workflow.

Branch propagation and publishing have additional guardrails. Follow the
maintenance runbook rather than copying CI or synchronization commands into a
new workflow.

## Project Documentation

- [Documentation map](docs/README.md): sources of truth and project glossary
- [Maintenance runbook](docs/maintenance.md): updates, branch propagation,
  image verification, and releases
- [Project decisions](docs/decisions.md): rationale for durable maintenance
  choices
- [Agent instructions](AGENTS.md): repository-specific guardrails for coding
  agents and automated maintainers
