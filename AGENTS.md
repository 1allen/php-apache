# Agent Notes

This repository builds custom `webdevops/php-apache` images with a newer
ImageMagick and PECL `imagick` than the upstream base image usually carries.

## Edit Priorities

- Keep shared maintenance edits on the `latest` branch first.
- Treat `config/php-branches.conf` as the source of truth for supported PHP
  branches and shared files.
- Keep `AGENTS.md`, `README.md`, `docs/maintenance.md`, scripts, config, and
  CI changes in `SHARED_FILES` when they should propagate to PHP version
  branches.
- Do not replace the manual `imagick` build with `install-php-extensions
  imagick` unless you have verified that the extension links against the custom
  ImageMagick under `/usr/local`.

## Dockerfile Rules

- `Dockerfile.ubuntu` is the maintained image path.
- The first stage copies `/usr/bin/install-php-extensions` from
  `ghcr.io/mlocati/php-extension-installer:latest` into the final image. Keep
  that binary in the final image so downstream images can install more
  extensions without fetching the installer again.
- Prefer `install-php-extensions` for ordinary extensions and downstream image
  customization, for example:

  ```Dockerfile
  FROM 1allen/php-apache:8.5
  RUN install-php-extensions protobuf grpc redis
  ```

- When documenting downstream `grpc`, `redis`, or `protobuf` customization,
  show `install-php-extensions` as the preferred path. Keep manual `pecl
  install` examples only as legacy or troubleshooting context.
- `imagick` is intentionally installed manually from PECL after the custom
  ImageMagick build is copied into `/usr/local` and `ldconfig /usr/local/lib`
  has run.
- `Dockerfile.ubuntu` is not part of shared-file sync. When image behavior
  changes on `latest`, apply the equivalent Dockerfile update to each `phpXX`
  branch while preserving that branch's `FROM webdevops/php-apache:X.Y` line
  and extension compatibility pins.
- Run `bash scripts/repo_sync.sh verify-image-tooling` before pushing image
  behavior updates. This catches the failure mode where README examples mention
  a downstream customization feature but semver branches such as `php82` do not
  actually include it in their committed Dockerfiles.
- If the base PHP minor changes, update only the `FROM webdevops/php-apache:X.Y`
  line on the corresponding `phpXX` branch unless shared behavior also changed.

## Update Checklist

1. Check upstream versions using `docs/maintenance.md`.
2. Update `ARG IMAGEMAGICK_VERSION` and `ARG IMAGICK_VERSION` only when current
   upstreams support the target PHP version.
3. Keep `install-php-extensions` in `/usr/local/bin`.
4. Run `bash tests/repo_sync_test.sh`.
5. For image behavior changes, verify the matching `phpXX` branches include the
   Dockerfile update before pushing semver tags such as `8.2`.
6. Run `bash scripts/repo_sync.sh verify-image-tooling`.
7. If Docker is available, run a local image build and verify:

   ```bash
   docker build --pull -f Dockerfile.ubuntu -t php-apache:local .
   docker run --rm php-apache:local php -m | grep -E '^(gmp|imagick)$'
   docker run --rm php-apache:local command -v install-php-extensions
   ```

8. Sync shared-file changes into PHP branches with:

   ```bash
   bash scripts/repo_sync.sh sync-shared
   ```
