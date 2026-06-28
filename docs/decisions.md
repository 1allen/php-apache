# Project Decisions

This file records durable project decisions. Keep details in the maintained
source files named by `docs/README.md`; decisions explain why the rules exist.

## Build Only From Latest

The `latest` branch is the integration branch for shared maintenance changes,
not a consumer PHP version line. CI should build PR branches and `latest` to
prove the image still builds, but Docker Hub publishing belongs to `phpXX`
branches and version-like git tags so published image names stay tied to the
project's branch and tag model.

CI-provider-specific YAML should stay as a thin adapter. The stable interface is
`scripts/ci/docker_build.sh` with normalized `CI_GIT_BRANCH`, `CI_GIT_TAG`, and
`CI_GIT_REF_TYPE` inputs, because this project expects to move off Semaphore CI
eventually.

Semaphore trigger selection is a project setting, not a pipeline-block concern.
Use YAML to describe the build and publish flow, but use Semaphore's "What to
build" settings to avoid duplicate PR statuses from both pull-request and
ordinary branch-push workflows.

## Semaphore Buildx Cache

Semaphore's cache should accelerate builds, not define the build contract. The
pipeline restores and stores a local Buildx cache directory with a sanitized
branch or tag key and a shared `docker-buildx-latest` fallback key, while
`scripts/ci/docker_build.sh` keeps Docker registry cache sources as the
provider-neutral baseline.

The local cache path is enabled through `DOCKER_BUILDX_CACHE_DIR`. When that
variable is unset, the script uses plain `docker build`; when it is set, the
script uses `docker buildx build --load` with local cache import/export so the
publish step still pushes the same local image tag.

## Post-Publish Security Scan

Final image scanning belongs in a separate post-publish step while the project
is still using advisory vulnerability scans. The scan should target the exact
pushed Docker Hub ref for each `phpXX` branch or version-like tag and should not
block publishing until the project deliberately promotes it to a gate.

Keep the scan policy in `scripts/ci/trivy_scan.sh` so the behavior follows the
image publish path across CI providers. Semaphore may expose it as a separate
post-publish block, but the provider adapter should not own the scan policy.

## Stage ImageMagick With DESTDIR

ImageMagick should be configured with its runtime prefix as `/usr/local` and
installed into a temporary staging root with `make install DESTDIR=/tmp/imgck`.
This keeps copied artifact paths aligned with their runtime location while still
allowing the final image to copy only the staged `/usr/local` tree from the
builder stage.
