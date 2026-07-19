# Agent Notes

This repository builds custom `webdevops/php-apache` images with a newer
ImageMagick and PECL `imagick` than the upstream base image usually carries.

Read [docs/README.md](docs/README.md) first. It identifies the maintained
sources of truth and glossary. Use [docs/maintenance.md](docs/maintenance.md)
for the runbook and [docs/decisions.md](docs/decisions.md) for rationale.

## Guardrails

- Make shared maintenance edits on `latest` first.
- Treat `config/php-branches.conf` as the source of truth for supported PHP
  branches, shared files, provider-neutral Docker image defaults, publish tag
  patterns, accepted PHP extension installer image refs, and release behavior.
- Keep `AGENTS.md`, `README.md`, `docs/README.md`, `docs/maintenance.md`,
  `docs/decisions.md`, scripts, config, and CI changes in `SHARED_FILES` when
  they should propagate to PHP version branches.
- Treat `php73` and `php74` as deprecated/frozen. Do not sync shared files,
  update Dockerfile behavior, or move PHP 7 tags unless explicitly asked for a
  critical emergency fix.
- `Dockerfile.ubuntu` is the maintained image path. `Dockerfile.ubuntu` is not a
  shared file; apply equivalent Dockerfile behavior to supported `phpXX`
  branches intentionally while preserving each branch's base PHP minor and
  builder/runtime ABI compatibility pins.
- `imagick` is a bundled feature. Keep the explicit pinned PECL source build so
  it links against custom ImageMagick under `/usr/local`.
- Keep application-specific PHP extensions, including GMP, in downstream
  images. Keep `install-php-extensions` in the base image as a supported
  downstream customization interface.
- Keep `docker-php-ext-configure imagick --with-imagick=/usr/local`,
  SHA-256 verification for downloaded ImageMagick and PECL `imagick` archives,
  and `PKG_CONFIG_PATH=/usr/local/lib/pkgconfig` or equivalent configure-time
  pathing.
- Keep Docker build and publish behavior in `scripts/ci/docker_build.sh`; CI
  YAML should be a thin provider adapter. Semaphore is current, not permanent.
- Treat the documented maintenance interfaces as authoritative before designing
  any workflow. Map the requested outcome to `scripts/repo_sync.sh`,
  `scripts/ci/docker_build.sh`, `scripts/ci/release_status.sh`,
  `scripts/ci/trivy_scan.sh`,
  `scripts/tags_update.sh`, `scripts/image_metrics.sh`,
  `scripts/docker_hub_cleanup.sh`, and the branch flow in
  `docs/maintenance.md` first.
- Do not propose parallel rollout PRs, temporary rollout branches, replacement
  scripts, or new orchestration unless an exact requirement unsupported by the
  existing interfaces has been demonstrated. Document that gap and obtain
  explicit approval before designing an alternative; generic best practices do
  not override this repository's instructions.
- Before merge, propagation, publish, tag movement, or issue-state changes,
  preview the exact commands and effects and compare them with the maintenance
  runbook. If the documented route or its effect is unclear, stop and ask
  instead of inventing a workflow.
- Do not move version tags after documentation, test, or CI-adapter-only changes.
  Move tags only when release image inputs changed or an explicit rebuild is
  intended; branch synchronization does not automatically imply publication.
- Keep provider-ref classification in `scripts/lib/release_ref.sh`, maintained
  Dockerfile invariants in `scripts/lib/image_contract.sh`, and temporary Git
  worktree mechanics in `scripts/lib/git_worktree.sh`.
- Keep WebP support in the base image and verify it through ImageMagick and PHP
  imagick. Keep `jpegoptim`, the `webp` CLI, `ffmpeg`, and `mariadb-client` as
  documented downstream options rather than bundled base-image tools.
- Keep the image headless with ImageMagick `--without-x`; do not restore
  `libxt6` unless X11 operations become an explicit maintained feature.
- Measure cleanup results with the Docker Hub linux/amd64 compressed size from
  `scripts/image_metrics.sh`; do not compare local virtual image size with
  registry-compressed bytes.
- PR branches and `latest` are build-only. PHP branches are preflight-only and
  must not build or publish branch-named images. Docker Hub publishing is
  limited to version-like Git tags.

## Required Checks

```bash
bash tests/repo_sync_test.sh
bash scripts/repo_sync.sh verify-image-tooling latest
```

After supported branch Dockerfiles have been updated:

```bash
bash scripts/repo_sync.sh verify-image-tooling
```
