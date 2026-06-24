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
- `php73`-`php74`: legacy version branches still tracked in the manifest

FYI the `latest` branch contains the latest changes, not necessarily the latest
PHP branch history.

## Build behavior

- pushes to `latest` build the `latest` image tag
- pushes to `phpXX` branches now build branch-specific image tags again
- git tags such as `8.4` still build tag-specific images

For PHP `8.5`, the Ubuntu Dockerfile now pins `imagick 3.8.1`, which is the
first recent PECL release line compatible with PHP `8.5`.

The Ubuntu image also copies `install-php-extensions` into `/usr/local/bin`.
Downstream images can use it directly:

```Dockerfile
FROM 1allen/php-apache:8.5

RUN install-php-extensions protobuf grpc redis
```

`imagick` remains a manual PECL build in this repository so it links against the
custom ImageMagick installed under `/usr/local`.

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

Preview shared-file drift from `latest` into all local PHP branches:

```bash
bash scripts/repo_sync.sh sync-shared
```

Apply that shared-file sync as branch-local commits:

```bash
bash scripts/repo_sync.sh sync-shared --apply
```

After syncing shared files into local `phpXX` branches, push those branches so
Semaphore triggers the corresponding branch builds.

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

Run the local repository test after changing Dockerfiles, scripts, config, or
shared documentation:

```bash
bash tests/repo_sync_test.sh
```

## LLM / automation notes

- Treat `config/php-branches.conf` as the source of truth for supported branches
  and shared files.
- Keep `AGENTS.md` and `docs/maintenance.md` in sync with Dockerfile behavior.
- Put shared maintenance changes on `latest` first, then use
  `bash scripts/repo_sync.sh sync-shared` to preview branch drift.
- Use `bootstrap-version` when upstream adds a new PHP minor tag so the repo has
  a predictable, reviewable starting point for that branch.
- Remote checks in `status` are advisory; the manifest stays authoritative if a
  network lookup is unavailable.
