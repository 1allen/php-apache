# Project Documentation

This directory holds maintained project documentation. Keep each topic in one
source of truth and link to it instead of copying the same policy into several
files.

## Sources Of Truth

- `config/php-branches.conf`: supported PHP branches, legacy branches, shared
  files, provider-neutral Docker image defaults, and publish tag pattern.
- `scripts/ci/docker_build.sh`: CI-provider-neutral Docker build and publish
  behavior. Semaphore is only the current adapter.
- `scripts/ci/release_status.sh`: current and waiting status for supported
  publish pipelines through their GitHub commit-status context.
- `scripts/repo_sync.sh`: shared-file preview, local synchronization commits,
  verified atomic branch push, and version-branch bootstrap behavior.
- `scripts/docker_hub_cleanup.sh`: dry-run inventory and allowlisted retirement
  of floating and branch-named Docker Hub tags.
- `scripts/image_metrics.sh` and `config/image-size-baseline.tsv`: read-only
  Docker Hub compressed-size reporting, optional CI build-timing joins, and the
  immutable pre-cleanup baseline.
- `scripts/lib/release_ref.sh`: provider-neutral ref normalization, build and
  publish eligibility, and PHP-branch tag conversion.
- `scripts/lib/image_contract.sh`: maintained Dockerfile invariants for custom
  ImageMagick, bundled imagick, and WebP support.
- `scripts/lib/git_worktree.sh`: temporary worktree transaction lifecycle used
  by repository synchronization and version bootstrap flows.
- `Dockerfile.ubuntu`: maintained `latest` image build path.
- `docs/maintenance.md`: human maintenance runbook for updates, branch
  propagation, image verification, and release flow.
- `docs/decisions.md`: short decision records. Decisions explain why a rule
  exists; they do not replace the runbook or scripts.

## Maintenance Rule

When behavior changes, update the source of truth first, then adjust only the
short pointers in `README.md` and `AGENTS.md`.

## Glossary

**PHP branch**: a repository branch named for a PHP minor line, such as `php73`,
`php74`, or `php85`. These names are canonical.

**Supported PHP branch**: a PHP branch that participates in default maintenance
commands and routine image updates.

**PHP 7 branch**: one of the existing PHP branches for PHP 7, currently `php73`
and `php74`. Maintenance that touches these branches must name them explicitly.

**Build-only CI**: a CI run that builds the Dockerfile as a smoke test without
tagging or publishing an image.

**Release-source preflight**: a Docker-free CI check that validates the current
PHP branch or version-tag Dockerfile against the maintained image contract.
Only a version-like Git tag proceeds from preflight to build and publish.

**Bundled imagick**: the PECL `imagick` extension included in the published
image and linked against the custom ImageMagick installation under `/usr/local`.

**Optional application tooling**: operating-system commands such as
`jpegoptim`, `webp`, `ffmpeg`, and `mariadb-client` that downstream images add
when their application uses them. They are not part of the base image contract.

**Shared file**: a repository maintenance file that should be propagated from
`latest` to PHP branches because it is not branch-version-specific.

**Rootless Docker daemon**: a Docker daemon running inside the invoking user's
user namespace. Container UID `0` maps to that unprivileged host user; it does
not mean host UID `0`.

**Non-root container process**: a process with a nonzero UID inside its
container. This is separate from whether the Docker daemon itself is rootless.
