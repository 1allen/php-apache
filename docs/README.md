# Project Documentation

This directory holds maintained project documentation. Keep each topic in one
source of truth and link to it instead of copying the same policy into several
files.

## Sources Of Truth

- `config/php-branches.conf`: supported PHP branches, legacy branches, shared
  files, Semaphore machine defaults, publish tag pattern, and accepted PHP
  extension installer image refs.
- `scripts/ci/docker_build.sh`: CI-provider-neutral Docker build and publish
  behavior. Semaphore is only the current adapter.
- `Dockerfile.ubuntu`: maintained `latest` image build path.
- `docs/maintenance.md`: human maintenance runbook for updates, branch
  propagation, image verification, and release flow.
- `docs/decisions.md`: short decision records. Decisions explain why a rule
  exists; they do not replace the runbook or scripts.
- `CONTEXT.md`: glossary for agent terminology.

## Maintenance Rule

When behavior changes, update the source of truth first, then adjust only the
short pointers in `README.md` and `AGENTS.md`.
