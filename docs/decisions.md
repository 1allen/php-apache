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

## Image-Line Cache Identity

Cache identity follows the Dockerfile base PHP minor line, not the repository
branch name and not Docker Hub `latest`. The `latest` branch is an integration
branch and this project does not publish `1allen/php-apache:latest`, so using
that tag as a cache source is misleading and can silently depend on stale or
absent registry state.

The provider-neutral script derives an image line such as `php85` from
`Dockerfile.ubuntu` by reading the `webdevops/php-apache:8.5` base image. Docker
registry cache sources and CI cache keys use that image line. This keeps cache
reuse per PHP version, including when the `latest` branch currently builds the
same PHP minor as a supported branch.

## CI Adapters And Artifacts

CI-specific YAML should stay declarative and thin. Provider-neutral Docker
image lifecycle behavior belongs in `scripts/ci/docker_build.sh`; provider
storage commands belong in small adapter scripts such as
`scripts/ci/semaphore_build.sh`.

Semaphore cache accelerates Buildx by restoring and storing a local cache
directory scoped by image line. It is not an artifact handoff and it is not
authoritative. For publishable refs, the root pipeline builds the Docker image
once and pushes a workflow artifact containing `docker save` output. The
promoted publish pipeline pulls that workflow artifact, loads it, and pushes
the exact built image. PR and `latest` build-only refs do not upload image
artifacts because no downstream publish block consumes them.

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
