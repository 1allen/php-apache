# Agent Notes

This repository builds custom `webdevops/php-apache` images with a newer
ImageMagick and PECL `imagick` than the upstream base image usually carries.

Read [docs/README.md](docs/README.md) first. It identifies the maintained
sources of truth and glossary. Use [docs/maintenance.md](docs/maintenance.md)
for the runbook and [docs/decisions.md](docs/decisions.md) for rationale.

## Guardrails

- Make shared maintenance edits on `latest` first.
- Treat `config/php-branches.conf` as the source of truth for supported PHP
  branches, shared files, CI constants, publish tag patterns, and accepted
  installer image refs.
- Keep `AGENTS.md`, `README.md`, `docs/README.md`, `docs/maintenance.md`,
  `docs/decisions.md`, scripts, config, and CI changes in `SHARED_FILES` when
  they should propagate to PHP version branches.
- Treat `php73` and `php74` as deprecated/frozen. Do not sync shared files,
  update Dockerfile behavior, or move PHP 7 tags unless explicitly asked for a
  critical emergency fix.
- `Dockerfile.ubuntu` is the maintained image path. `Dockerfile.ubuntu` is not a
  shared file; apply equivalent Dockerfile behavior to supported `phpXX`
  branches intentionally while preserving each branch's base PHP minor.
- `imagick` is a bundled feature. Keep the explicit pinned PECL source build
  unless you have verified that another installer path still ships `imagick` by
  default and links against custom ImageMagick under `/usr/local`.
- Keep `docker-php-ext-configure imagick --with-imagick=/usr/local`,
  SHA-256 verification for downloaded ImageMagick and PECL `imagick` archives,
  and `PKG_CONFIG_PATH=/usr/local/lib/pkgconfig` or equivalent configure-time
  pathing.
- Keep Docker build and publish behavior in `scripts/ci/docker_build.sh`; CI
  YAML should be a thin provider adapter. Semaphore is current, not permanent.
- PR branches and `latest` are build-only. Docker Hub publishing is limited to
  `phpXX` branches and version-like git tags.

## Required Checks

```bash
bash tests/repo_sync_test.sh
bash scripts/repo_sync.sh verify-image-tooling latest
```

After supported branch Dockerfiles have been updated:

```bash
bash scripts/repo_sync.sh verify-image-tooling
```
