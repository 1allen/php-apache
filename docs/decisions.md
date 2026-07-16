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

Provider variables terminate at `scripts/lib/release_ref.sh`. That module owns
normalization, build and publish classification, and PHP-branch tag conversion;
the Docker build, post-publish scan, and tag update scripts remain separate
adapters.

Semaphore trigger selection is a project setting, not a pipeline-block concern.
Use YAML to describe the build and publish flow, but use Semaphore's "What to
build" settings to avoid duplicate PR statuses from both pull-request and
ordinary branch-push workflows.

## Post-Publish Security Scan

Final image scanning belongs in a separate post-publish step while the project
is still using advisory vulnerability scans. The scan should target the exact
pushed Docker Hub ref for each `phpXX` branch or version-like tag and should not
block publishing until the project deliberately promotes it to a gate.

Keep the scan policy in `scripts/ci/trivy_scan.sh` so the behavior follows the
image publish path across CI providers. Semaphore may expose it as a separate
post-publish block, but the provider adapter should not own the scan policy.

## Measure Registry-Compressed Image Size

Image cleanup is measured with Docker Hub's compressed linux/amd64 manifest
size, not the local Docker virtual size. The registry metric is reproducible
without pulling every image and matches the bytes consumers transfer, while
local size can vary with Docker's storage driver and shared layers.

Keep reporting read-only and separate from build, publish, and scan policy.
`scripts/image_metrics.sh` reads current Docker Hub metadata and compares it
with the immutable pre-cleanup snapshot in
`config/image-size-baseline.tsv`. A release can record the report in its issue
without making size reduction a publish gate.

## Stage ImageMagick With DESTDIR

ImageMagick should be configured with its runtime prefix as `/usr/local` and
installed into a temporary staging root with `make install DESTDIR=/tmp/imgck`.
This keeps copied artifact paths aligned with their runtime location while still
allowing the final image to copy only the staged `/usr/local` tree from the
builder stage.

The builder's distribution must remain compatible with the final branch base
for dynamically linked libraries outside that staged tree. Older image lines
may pin a matching builder distribution; in particular, `php80` pairs its
Buster runtime with `spritsail/debian-builder:buster`.

## Keep The Base Image Focused

The maintained image contract is Apache/PHP with custom ImageMagick, bundled
imagick and GMP, tested WebP support, and downstream PHP-extension installation.
Standalone image, media, and database command-line tools are application
choices. Keep `jpegoptim`, `webp`, `ffmpeg`, and `mariadb-client` in downstream
Dockerfiles so applications can preserve their production behavior without
making every consumer inherit those packages and dependency trees.

WebP format support is different from the `webp` CLI. Build ImageMagick with
`libwebp-dev`, install its runtime libraries explicitly in the final stage, and
test WebP through both ImageMagick and PHP imagick.

The image is headless and does not promise ImageMagick's X11 commands. Configure
ImageMagick with `--without-x` instead of carrying `libxt6` solely to satisfy an
unused display interface.

## Use One Image For Rootless Docker

Rootless Docker bind-mount compatibility should be an explicit runtime mode of
the existing image, not a separately built or published image. In a rootless
Docker user namespace, container UID `0` maps to the unprivileged host user
running the daemon. Configuring the inherited WebDevOps entrypoint to run
PHP-FPM as namespace UID `0`, together with PHP-FPM's explicit allow-root
option, therefore preserves host-user ownership for files PHP creates on bind
mounts.

The mode must remain opt-in and documented with a rootless-daemon check. The
same configuration on a rootful daemon would run PHP-FPM as actual container
root and create root-owned host files. A separate image tag would not remove
that runtime distinction and would add another branch of image behavior to
maintain.

## Concentrate Maintenance Policy

Release-ref classification, image-contract validation, and temporary Git
worktree lifecycle each have one maintained module under `scripts/lib`. CI,
repository synchronization, and tag scripts are adapters at those seams. Tests
should exercise module interfaces and command outcomes rather than duplicating
private implementation text.

## Use Existing Maintenance Interfaces First

Repository maintenance is not a blank-slate workflow-design exercise. The
runbook and maintained scripts are project interfaces that encode branch,
release, provider-neutral CI, and frozen-version policy. Work must first route
through `scripts/repo_sync.sh sync-shared`, `scripts/repo_sync.sh
verify-image-tooling`, `scripts/ci/docker_build.sh`,
`scripts/ci/trivy_scan.sh`, and `scripts/tags_update.sh`, as applicable.

Do not replace that flow with parallel rollout pull requests, temporary rollout
branches, duplicate scripts, or new orchestration merely because another
workflow is common elsewhere. An alternative requires a concrete unsupported
requirement, a documented gap in the current interface, and explicit approval.
When the current behavior is unclear, inspect the implementation and ask rather
than infer a replacement process.

This preserves repository-specific operational knowledge, avoids competing
release paths, and keeps future agents and maintainers from turning documented
automation back into manual coordination.
