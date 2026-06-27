# php-apache

Custom `webdevops/php-apache` images with a newer ImageMagick build, PECL
`imagick`, WebP support, and the mlocati `install-php-extensions` helper kept
inside the final image for downstream customization.

Upstream base image:
[webdevops/php-apache on Docker Hub](https://hub.docker.com/r/webdevops/php-apache).
Upstream source repository:
[webdevops/Dockerfile on GitHub](https://github.com/webdevops/Dockerfile).

See [docs/maintenance.md](docs/maintenance.md) for the full update runbook and
[AGENTS.md](AGENTS.md) for AI/agent-specific maintenance notes.

`latest` is the integration branch for shared maintenance updates. Published PHP
versions continue to live on their own `phpXX` branches because the Docker build
steps can diverge by version.

## Branch model

- `latest`: integration branch for shared repo changes
- `php80`-`php85`: actively supported version branches
- `php73`-`php74`: deprecated/frozen version branches, kept only for critical
  emergency maintenance

FYI the `latest` branch contains the latest changes, not necessarily the latest
PHP branch history.

## Build behavior

- PR branches and pushes to `latest` run build-only checks and do not publish
  Docker images or receive Docker Hub secrets
- ordinary feature-branch push workflows are skipped when a PR workflow exists,
  so the same commit is not built twice
- pushes to `phpXX` branches publish branch-specific image tags
- git tags such as `8.4` publish tag-specific images
- Semaphore uses BuildKit inline cache metadata and pulls both the target tag
  and `latest` as cache sources before building
- publishable `phpXX` branches and git tags build once in a separate Docker Hub
  block and push from that same job
- Semaphore uses `e1-standard-2` by default to keep build-only PR checks small;
  bump only if the Docker build proves it needs more memory or disk.

The Docker build and publish logic lives in `scripts/ci/docker_build.sh` so CI
configuration stays thin. Other CI providers can call the same script by setting
`CI_GIT_BRANCH` and `CI_GIT_TAG` from their native branch/tag variables.

For PHP `8.5`, the Ubuntu Dockerfile now pins `imagick 3.8.1`, which is the
first recent PECL release line compatible with PHP `8.5`.

The Ubuntu image also copies `install-php-extensions` into `/usr/local/bin`.
Downstream images can use it directly:

```Dockerfile
FROM 1allen/php-apache:8.5

RUN install-php-extensions protobuf grpc redis
```

`imagick` is still bundled in the published image. This repository builds the
pinned PECL source explicitly during the image build so the extension links
against the custom ImageMagick installed under `/usr/local`.

Source downloads for ImageMagick and PECL `imagick` are SHA-256 verified in the
Dockerfile. When either version pin changes, update the matching checksum in the
same change.

For the common local customization case that previously looked like this:

```Dockerfile
RUN apt-get update && apt-get install -y zlib1g-dev \
    && pecl install grpc \
    && pecl install redis
RUN docker-php-ext-enable grpc redis
```

prefer the bundled installer instead:

```Dockerfile
FROM 1allen/php-apache:8.5

RUN install-php-extensions grpc redis protobuf
```

The installer handles build dependencies and enables installed extensions, so
custom images stay shorter and easier to update.

## Maintenance commands

Check the current repo and upstream state:

```bash
bash scripts/repo_sync.sh status
```

Preview shared-file drift from `latest` into supported local PHP branches:

```bash
bash scripts/repo_sync.sh sync-shared
```

Apply that shared-file sync as branch-local commits:

```bash
bash scripts/repo_sync.sh sync-shared --apply
```

`sync-shared` targets supported PHP branches by default. Deprecated PHP 7
branches are skipped unless you pass explicit branch names for critical
maintenance.

After syncing shared files into local supported `phpXX` branches, push those
branches so Semaphore triggers the corresponding branch image builds.

Preview a new PHP branch bootstrap from `latest`:

```bash
bash scripts/repo_sync.sh bootstrap-version php85
```

Create the new local branch and seed its first commit:

```bash
bash scripts/repo_sync.sh bootstrap-version php85 --apply
```

Preview Docker tag updates for configured branches:

```bash
bash scripts/tags_update.sh
```

Push those tag updates:

```bash
bash scripts/tags_update.sh --apply
```

Tag updates also target supported PHP branches by default. Deprecated PHP 7 tags
are left in place unless you deliberately name those branches, for example
`bash scripts/tags_update.sh --apply php73 php74`.

Run the local repository test after changing Dockerfiles, scripts, config, or
shared documentation:

```bash
bash tests/repo_sync_test.sh
```

For image behavior changes, also verify that the supported PHP branches still
carry the required Dockerfile tooling:

```bash
bash scripts/repo_sync.sh verify-image-tooling
```

## LLM / automation notes

- Treat `config/php-branches.conf` as the source of truth for supported branches
  and shared files.
- Keep `AGENTS.md` and `docs/maintenance.md` in sync with Dockerfile behavior.
- Keep `.dockerignore` in shared-file sync so CI build contexts stay small on
  every PHP branch.
- Preserve SHA-256 verification for ImageMagick and PECL `imagick` downloads.
- Put shared maintenance changes on `latest` first, then use
  `bash scripts/repo_sync.sh sync-shared` to preview branch drift.
- Treat `php73` and `php74` as deprecated/frozen. Do not sync shared files,
  update tags, or refresh Dockerfile behavior there unless the change is a
  critical emergency fix.
- Use `bootstrap-version` when upstream adds a new PHP minor tag so the repo has
  a predictable, reviewable starting point for that branch.
- Remote checks in `status` are advisory; the manifest stays authoritative if a
  network lookup is unavailable.
