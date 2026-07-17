# Project Decisions

This file records durable project decisions. Keep details in the maintained
source files named by `docs/README.md`; decisions explain why the rules exist.

## Publish Version Tags Once

The `latest` branch is the integration branch for shared maintenance changes,
not a consumer PHP version line. CI should build PR branches and `latest` to
prove the maintained image still builds. PHP branches hold the version-specific
Dockerfiles and receive a Docker-free image-contract preflight. They do not
publish branch-named images. Version-like Git tags are the only Docker Hub
publish refs.

Each version tag builds exactly once in the protected publish pipeline, pushes
only after the build succeeds, and then receives the advisory scan. The root
pipeline performs only the release-source preflight for version tags, avoiding
the previous build followed by an immediate rebuild. The build imports inline
cache metadata from the previous same tag and, for a patch tag, its minor tag.
PR and `latest` builds use the configured maintained minor tag as their cache
source instead of an unmaintained `latest` image.

Do not pass saved Docker images between CI jobs or create a dedicated writable
cache until measured build timings demonstrate that the remaining compilation
cost justifies the storage and credential overhead. Published semver images are
both the consumer artifact and the initial read-only cache source.

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
pushed version-like Docker Hub ref and should not block publishing until the
project deliberately promotes it to a gate.

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
`config/image-size-baseline.tsv`. The current side uses consumer `X.Y` tags;
the preserved baseline rows retain their historical `phpXX` names. A release
can record the report in its issue without making size reduction a publish
gate.

## Join Build And Image Metrics At A File Seam

Build timing and registry size come from different moments in the release job:
the Docker build knows elapsed cache-preparation, build, and push time, while
Docker Hub knows the final compressed size and digest only after publication.
Join them through a small provider-neutral TSV file rather than coupling Docker
Hub queries into `scripts/ci/docker_build.sh` or adding CI artifact storage.

`scripts/ci/docker_build.sh` optionally writes the timing record after a
successful push. `scripts/image_metrics.sh --build-metrics FILE` consumes that
record, infers its version tags, and joins it with registry metrics. Semaphore
only selects the temporary path and invokes both maintained interfaces in the
same job. Other CI providers can use the same file interface.

The report is non-blocking after a successful push. Registry reporting failures
must remain visible as warnings, but must not turn an already-published image
into a failed release or prevent its advisory security scan.

Report cache preparation, build, publish, and total wall-clock seconds together
with compressed bytes, baseline savings, digest, and attempted cache sources.
Do not label attempted sources as cache hits. Add hit-rate reporting only when
the builder exposes a stable machine-readable signal that does not require
parsing presentation-oriented logs.

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

## Automate Repeatable External Effects Behind Apply Gates

Routine branch propagation and registry retirement must be maintained
interfaces, not command sequences reconstructed by each operator. Keep local
shared-file commit creation and remote branch mutation as separate phases of
`scripts/repo_sync.sh sync-shared`: `--apply` creates the commits, required
checks run against those commits, and `--push` first proves that no shared-file
drift remains before atomically pushing the complete target branch set. A
missing, divergent, or unsynchronized branch must fail the push rather than
silently producing a partial rollout.

Keep destructive Docker Hub retirement in `scripts/docker_hub_cleanup.sh`, not
in the read-only image metrics module or CI publication path. Its default mode
inventories the repository and previews the exact retired tags. `--apply`
authenticates only when deletions are required, derives its strict allowlist
from `latest` plus configured PHP branch names, refuses version-like deletion
targets, deletes only tags currently present, and verifies that none remain.
The version-like consumer tags and any unrecognized tags remain untouched.

These interfaces deepen existing workflow seams: callers select a reviewed
phase while branch enumeration, atomicity, deletion policy, authentication,
and verification remain local to the maintained scripts. They do not turn
one-time registry retirement into an automatic CI side effect.

## Use Existing Maintenance Interfaces First

Repository maintenance is not a blank-slate workflow-design exercise. The
runbook and maintained scripts are project interfaces that encode branch,
release, provider-neutral CI, and frozen-version policy. Work must first route
through `scripts/repo_sync.sh sync-shared`, `scripts/repo_sync.sh
verify-image-tooling`, `scripts/ci/docker_build.sh`,
`scripts/ci/trivy_scan.sh`, `scripts/tags_update.sh`, and
`scripts/docker_hub_cleanup.sh`, as applicable.

Do not replace that flow with parallel rollout pull requests, temporary rollout
branches, duplicate scripts, or new orchestration merely because another
workflow is common elsewhere. An alternative requires a concrete unsupported
requirement, a documented gap in the current interface, and explicit approval.
When the current behavior is unclear, inspect the implementation and ask rather
than infer a replacement process.

This preserves repository-specific operational knowledge, avoids competing
release paths, and keeps future agents and maintainers from turning documented
automation back into manual coordination.
