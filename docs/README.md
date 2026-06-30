# Project Documentation

This directory holds maintained project documentation. Keep each topic in one
source of truth and link to it instead of copying the same policy into several
files.

## Sources Of Truth

- `config/php-branches.conf`: supported PHP branches, legacy branches, shared
  files, provider-neutral Docker image defaults, publish tag pattern, and
  accepted PHP extension installer image refs.
- `scripts/ci/docker_build.sh`: CI-provider-neutral Docker image lifecycle
  operations. Build, artifact save/load, publish, and scan stages must stay
  separate.
- `scripts/ci/semaphore_build.sh`: Semaphore-specific cache and artifact
  adapter around the provider-neutral Docker lifecycle.
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

**Strict stage separation**: a CI design rule that build, publish, scan, and
other checks run as distinct stages. Later stages consume explicit CI artifacts
or published refs instead of rebuilding or repeating earlier stage work.

**Image line**: the PHP minor line derived from the maintained Dockerfile's
`webdevops/php-apache:X.Y` base image, expressed as a branch-like name such as
`php85`. Image-line identity scopes registry cache sources and CI cache keys.

**CI adapter**: a CI-provider-specific wrapper that maps provider variables,
cache commands, and artifact commands to the provider-neutral lifecycle scripts.
Semaphore is the current CI adapter, but it should not own Docker lifecycle
policy.

**Workflow artifact**: a CI artifact scoped to one workflow run and used to pass
the exact built Docker image from the build block to the promoted publish block.

**Bundled imagick**: the PECL `imagick` extension included in the published
image and linked against the custom ImageMagick installation under `/usr/local`.

**Shared file**: a repository maintenance file that should be propagated from
`latest` to PHP branches because it is not branch-version-specific.
