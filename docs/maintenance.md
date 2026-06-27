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
- ImageMagick and PECL `imagick` source archives are verified with SHA-256
  checksums in `Dockerfile.ubuntu`.
- `install-php-extensions` is copied from
  `ghcr.io/mlocati/php-extension-installer:latest` into `/usr/local/bin`.
- CI enables BuildKit inline cache metadata and uses both the target image tag
  and `latest` as cache sources. PR branches and `latest` are build-only;
  Docker Hub publishing is reserved for `phpXX` branches and git tags.
- CI declaration files call `scripts/ci/docker_build.sh` instead of embedding
  the Docker build and publish shell logic. New CI providers should map their
  native branch/tag variables to `CI_GIT_BRANCH` and `CI_GIT_TAG` before calling
  that script.
- `.dockerignore` intentionally keeps repo docs, tests, scripts, local agent
  state, and Git metadata out of the Docker build context because the image does
  not copy files from the repository.
- PHP 7 branches (`php73`, `php74`) are deprecated/frozen. They remain available
  for existing consumers, but normal shared-file sync, Dockerfile behavior
  updates, and tag movement should skip them unless a critical emergency fix
  requires an explicit opt-in.

## Why Imagick Is Built Explicitly

The final image must continue to bundle `imagick`; it is one of the core
features of this repository. The build installs it from pinned PECL source so
it links against the custom ImageMagick copied from the `imagemagick-builder`
stage into `/usr/local`. The mlocati installer knows how to install `imagick`,
but on Debian it also manages distro ImageMagick packages. That is useful for
default images, but it can hide whether the extension linked to the custom
`/usr/local` ImageMagick build.

For that reason:

- use `install-php-extensions` for ordinary extensions such as `gmp`,
  `protobuf`, `grpc`, and `redis`;
- keep `imagick` bundled in this image and keep its PECL source build explicit
  unless you verify the linked libraries with `ldd`;
- run `ldconfig /usr/local/lib` before and after compiling `imagick`.
- configure `imagick` with `--with-imagick=/usr/local` so it uses the copied
  custom ImageMagick build instead of Debian's ImageMagick packages.

Useful verification commands after a build:

```bash
docker run --rm php-apache:local php -m | grep -E '^(gmp|imagick)$'
docker run --rm php-apache:local php --ri imagick
docker run --rm php-apache:local sh -lc 'ldd "$(php-config --extension-dir)/imagick.so" | grep -i magick'
docker run --rm php-apache:local command -v install-php-extensions
```

## Base-Image Compatibility Cleanup

The upstream `webdevops/php-apache` base can carry optional configuration for
components that are not usable in a derived image after package and extension
updates. The Dockerfile removes `/usr/local/etc/php/conf.d/00-ioncube.ini` only
when it points to a missing or unloadable ionCube loader, because that inherited
configuration causes PHP startup warnings even though ionCube is not part of
this image's maintained feature set.

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

Checksum update helpers for the currently pinned source archives:

```bash
IMAGEMAGICK_VERSION=7.1.2-26
IMAGICK_VERSION=3.8.1
curl -fsSL "https://github.com/ImageMagick/ImageMagick/archive/${IMAGEMAGICK_VERSION}.tar.gz" \
  | shasum -a 256
curl -fsSL "https://pecl.php.net/get/imagick-${IMAGICK_VERSION}.tgz" \
  | shasum -a 256
```

After updating versions, run:

```bash
bash tests/repo_sync_test.sh
bash scripts/repo_sync.sh verify-image-tooling latest
DOCKER_BUILDKIT=1 docker build --pull -f Dockerfile.ubuntu -t php-apache:local .
```

If the local Docker CLI falls back to the legacy builder, use Buildx instead:

```bash
docker buildx build --pull -f Dockerfile.ubuntu .
```

To exercise the same build decision logic used by CI, run the script directly:

```bash
CI_GIT_BRANCH=latest bash scripts/ci/docker_build.sh
CI_GIT_BRANCH=php85 DOCKER_PASSWORD=... bash scripts/ci/docker_build.sh
```

If the local Docker build is not practical, still run the shell test and review
the Dockerfile diff carefully. The real build happens in Semaphore. After
propagating Dockerfile behavior to supported PHP branches, run
`bash scripts/repo_sync.sh verify-image-tooling` before pushing those branch
updates.

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
you are debugging a PECL-specific failure and need to reproduce installer steps.

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
   `.dockerignore` is shared so build-context hygiene stays consistent.
3. If `Dockerfile.ubuntu` changes, apply the same Dockerfile behavior to each
   `phpXX` branch intentionally. `Dockerfile.ubuntu` is not a shared file
   because each branch can carry a different `FROM webdevops/php-apache:X.Y`
   and extension compatibility pin.
4. For a `latest`-only PR, verify the maintained Dockerfile on the review
   branch:

   ```bash
   bash scripts/repo_sync.sh verify-image-tooling latest
   ```

   After propagating Dockerfile behavior to supported PHP branches, verify every
   committed branch Dockerfile still exposes the expected downstream image
   tooling:

   ```bash
   bash scripts/repo_sync.sh verify-image-tooling
   ```

   This guard exists because documentation on `latest` can advertise a
   downstream customization feature before the semver branches actually include
   the Dockerfile support for it. PHP 7 branches `php73` and `php74` are tracked
   but are not part of the default supported-image guarantee; check them
   explicitly with `bash scripts/repo_sync.sh verify-image-tooling php73 php74`
   when changing those images.
5. Preview branch drift across supported PHP branches:

   ```bash
   bash scripts/repo_sync.sh sync-shared
   ```

6. Apply branch-local sync commits:

   ```bash
   bash scripts/repo_sync.sh sync-shared --apply
   ```

   Deprecated PHP 7 branches are skipped by default. For a critical emergency
   fix only, target them explicitly, for example:

   ```bash
   bash scripts/repo_sync.sh sync-shared php73 php74
   bash scripts/repo_sync.sh sync-shared --apply php73 php74
   ```

7. Push the updated PHP branches so Semaphore builds and publishes
   branch-specific image tags.
8. Preview and apply Docker tag updates when users consume semver image tags
   such as `1allen/php-apache:8.2`:

   ```bash
   bash scripts/tags_update.sh
   bash scripts/tags_update.sh --apply
   ```

   This updates supported PHP tags only. Deprecated PHP 7 tags are intentionally
   left where they are unless you name those branches explicitly for a critical
   emergency fix:

   ```bash
   bash scripts/tags_update.sh --apply php73 php74
   ```

## Reviewing Multi-Branch Changes

Keep `latest` as the main review surface for shared files. Review branch-local
Dockerfile changes separately because each `phpXX` branch can preserve a
different base PHP minor or extension compatibility pin.

Useful local review commands:

```bash
git status --short --branch
git diff --stat
git diff
for branch in php80 php81 php82 php83 php84 php85; do
  git log --oneline -1 "$branch"
  git diff "origin/$branch..$branch" -- Dockerfile.ubuntu
done
```

Before pushing, run:

```bash
bash tests/repo_sync_test.sh
bash scripts/repo_sync.sh verify-image-tooling latest
```

Open a PR against `latest` first for shared-file review. Semaphore builds the
PR and the eventual `latest` merge without publishing images. After review,
push the supported `phpXX` branches that carry Dockerfile commits so Semaphore
publishes branch-specific image tags. Leave `php73` and `php74` untouched unless
the change is a critical emergency fix.
