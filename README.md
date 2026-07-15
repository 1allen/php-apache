# php-apache

Maintained Apache and PHP container images based on
[`webdevops/php-apache`](https://hub.docker.com/r/webdevops/php-apache), with a
newer pinned ImageMagick build and PECL `imagick` linked against it.

The images are intended for PHP applications that need dependable image
processing, common media and database command-line tools, and a straightforward
way to add more PHP extensions downstream.

## Features

- Apache with PHP-FPM from the upstream WebDevOps image
- custom ImageMagick under `/usr/local`, including WebP support
- bundled PECL `imagick`, compiled against the custom ImageMagick build
- bundled `gmp` PHP extension
- `jpegoptim`, `webp`, `ffmpeg`, and the MariaDB client
- `install-php-extensions` available for downstream image customization
- published, PHP-minor-specific image tags rather than a floating development
  tag

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

## Downstream Extension Installs

The final image includes the mlocati extension installer, so a downstream image
can add supported extensions without downloading another installer:

```Dockerfile
FROM 1allen/php-apache:8.5

RUN install-php-extensions protobuf grpc redis
```

Pin extension versions in the downstream Dockerfile when reproducible builds
require them. The bundled `imagick` extension should remain unchanged because
it is intentionally compiled against this image's custom ImageMagick.

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
is not the recommended consumer image tag. Published PHP images come from the
supported `phpXX` branches and version-like git tags.

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
