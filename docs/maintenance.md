# Maintenance Runbook

This project maintains custom PHP Apache images derived from
`webdevops/php-apache`. Its purpose is a newer pinned ImageMagick build with
verified WebP support and PECL `imagick` explicitly linked against it.
Application-specific PHP extensions and command-line tools belong in downstream
images.

Upstream references:

- Docker Hub image:
  `https://hub.docker.com/r/webdevops/php-apache`
- Source repository:
  `https://github.com/webdevops/Dockerfile`
- mlocati PHP extension installer:
  `https://github.com/mlocati/docker-php-extension-installer`

Related project decisions are recorded in `docs/decisions.md`.

## Current Image Decisions

As of 2026-07-16:

- `webdevops/php-apache:8.5` is the current Ubuntu base used by
  `Dockerfile.ubuntu`.
- ImageMagick is pinned to `7.1.2-26`.
- PECL `imagick` is pinned to `3.8.1`.
- ImageMagick and PECL `imagick` source archives are verified with SHA-256
  checksums in `Dockerfile.ubuntu`.
- The final stage installs WebP runtime libraries explicitly and verifies that
  both ImageMagick and PHP imagick expose working WebP support. The standalone
  `webp` CLI package is optional downstream tooling.
- ImageMagick is configured with `--without-x`; this headless server image does
  not bundle `libxt6` or promise the X11-only display commands.
- CI enables BuildKit inline cache metadata. A version-tag build uses its
  previous same tag as the primary cache source; a patch tag also falls back to
  its `X.Y` tag. PR and `latest` builds use `DEFAULT_BUILD_CACHE_TAG`. CI does
  not use or publish a floating `latest` cache image.
- PRs and `latest` run the full build-only smoke check. PHP branch pushes and
  version tags run a Docker-free release-source preflight. Only a passed
  version-like Git tag auto-promotes to `.semaphore/publish.yml`, where one
  `build-publish` execution is followed by `scan published image`.
- Version-like Git tags are the only Docker Hub publish refs. PHP branch names
  remain repository source lines and must not become Docker image tags.
- Semaphore project triggers still control whether GitHub receives both
  `ci/semaphoreci/pr` and `ci/semaphoreci/push` statuses for a PR branch
  commit. YAML `run.when` can skip blocks, but it cannot prevent Semaphore from
  creating a push workflow/status. In Semaphore project settings, keep pull
  requests enabled, allow branch workflows only for `latest` and supported
  `phpXX` branches, and allow tag workflows only for version-like tags.
- After a successful publish, the promoted publish pipeline runs
  `scripts/image_metrics.sh --build-metrics` in the publish job to report cache
  preparation, build, publish, and total seconds together with the pushed
  image's compressed size, baseline savings, digest, and cache sources. It then
  runs
  `scripts/ci/trivy_scan.sh` against the final pushed image ref. This scan is
  advisory and non-blocking for now; failed scans should be reviewed but should
  not fail publishing until the project intentionally promotes the scan to a
  pre-publish or publish gate.
- Semaphore does not pass Docker image artifacts between jobs and does not keep
  a dedicated writable registry cache. Published semver images provide the
  initial read-only inline cache without extra artifact storage.
- Docker Hub retirement is available through the manual Docker Hub cleanup workflow
  in GitHub Actions. It has only a `workflow_dispatch` trigger, requires
  the `latest` branch, and reads the deletion-capable Docker Hub PAT from the
  protected `DOCKER_HUB_TOKEN` Actions secret.
- CI declaration files call `scripts/ci/docker_build.sh` instead of embedding
  the Docker build and publish shell logic. Semaphore is the current CI adapter,
  not the long-term interface. New CI providers should map their native
  branch/tag/ref variables to `CI_GIT_BRANCH`, `CI_GIT_TAG`, and
  `CI_GIT_REF_TYPE` before calling that script.
- Publish-capable git tags must match the version-like tag pattern in
  `config/php-branches.conf`.
- Semaphore uses `e1-standard-2` to keep build-only PR checks on the smallest
  Ubuntu x64 2-vCPU machine. This is a Semaphore adapter setting in
  `.semaphore/semaphore.yml`, not a provider-neutral manifest value. If
  ImageMagick builds fail from memory or disk pressure, use `f1-standard-2` as
  the next fallback and document the failure.
- `.dockerignore` intentionally keeps repo docs, tests, scripts, local agent
  state, and Git metadata out of the Docker build context because the image does
  not copy files from the repository.
- PHP 7 branches (`php73`, `php74`) are deprecated/frozen. They remain available
  for existing consumers, but normal shared-file sync, Dockerfile behavior
  updates, and tag movement should skip them unless a critical emergency fix
  requires an explicit opt-in.

## Why Imagick Is Built Explicitly

The final image must continue to bundle `imagick`; it is one of the two core
features of this repository. The build installs it from pinned PECL source so
it links against the custom ImageMagick copied from the `imagemagick-builder`
stage into `/usr/local`. General-purpose extension installers can also manage
distro ImageMagick packages, which can hide whether the extension linked to the
custom `/usr/local` build.

For that reason:

- install application-specific extensions such as `protobuf`, `grpc`, and
  `redis` in downstream images;
- keep `imagick` bundled in this image and keep its PECL source build explicit
  unless you verify the linked libraries with `ldd`;
- run `ldconfig /usr/local/lib` before and after compiling `imagick`.
- configure `imagick` with `--with-imagick=/usr/local` so it uses the copied
  custom ImageMagick build instead of Debian's ImageMagick packages.

Useful verification commands after a build:

```bash
docker run --rm php-apache:local php -m | grep -E '^imagick$'
docker run --rm php-apache:local php --ri imagick
docker run --rm php-apache:local sh -lc 'ldd "$(php-config --extension-dir)/imagick.so" | grep -i magick'
docker run --rm php-apache:local sh -lc 'magick -size 2x2 xc:white /tmp/check.webp && magick identify /tmp/check.webp'
docker run --rm php-apache:local php -r 'var_export(Imagick::queryFormats("WEBP"));'
```

## Base-Image Compatibility Cleanup

The upstream `webdevops/php-apache` base can carry optional configuration for
components that are not usable in a derived image after package and extension
updates. The Dockerfile removes `/usr/local/etc/php/conf.d/00-ioncube.ini` only
when it points to a missing or unloadable ionCube loader, because that inherited
configuration causes PHP startup warnings even though ionCube is not part of
this image's maintained feature set.

The ImageMagick builder distribution must also be ABI-compatible with the final
runtime base for shared libraries that are not staged under `/usr/local`.
`php80` uses the Buster base and therefore pins
`spritsail/debian-builder:buster`; using the floating builder links ImageMagick
to newer libraries such as `libtiff.so.6` that Buster cannot provide. Preserve
branch-local builder pins while applying equivalent Dockerfile behavior.

## Rootless Docker Bind Mounts

Use one published image for both ordinary and rootless Docker environments.
Rootless support is a runtime configuration, not a separate Dockerfile or image
tag.

A rootless Docker daemon runs containers in the invoking user's user namespace.
Container UID `0` maps to the unprivileged user running that daemon. A nonzero
container UID instead maps to a subordinate host UID, so setting
`APPLICATION_UID`, `APPLICATION_GID`, or the Dockerfile build arguments to the
host user's numeric IDs does not align bind-mount ownership in rootless mode.

First confirm that the active daemon is rootless:

```bash
docker info --format '{{range .SecurityOptions}}{{println .}}{{end}}' \
  | grep -F rootless
```

Then configure the service explicitly:

```yaml
services:
  php:
    image: 1allen/php-apache:8.5
    user: "0:0"
    environment:
      CONTAINER_UID: "0"
      SERVICE_PHPFPM_OPTS: "-R"
    volumes:
      - .:/app
```

`CONTAINER_UID=0` makes the inherited WebDevOps entrypoint configure the
PHP-FPM pool for namespace UID `0`. PHP-FPM normally refuses that UID, so
`SERVICE_PHPFPM_OPTS=-R` supplies its explicit allow-root option. The top-level
`user: "0:0"` makes the intended namespace identity visible in the Compose
configuration. PHP and commands executed in the service then create
bind-mounted files as the host user that owns the rootless daemon.

Do not use this mode with a rootful Docker daemon. In rootful mode these values
run PHP-FPM as real container root and create root-owned files on host bind
mounts. Keep the override in a rootless-specific Compose file or profile rather
than in a portable default service definition.

Verify the result against a disposable file in the mounted application path:

```bash
docker compose exec php php -r \
  'file_put_contents("/app/.rootless-write-test", "ok\n");'
test "$(stat -c %u .rootless-write-test)" -eq "$(id -u)"
rm .rootless-write-test
```

If policy also requires PHP-FPM to have a nonzero UID inside the container,
stock rootless Docker cannot guarantee that newly created bind-mounted files
are owned by the daemon's host user. Use a runtime with keep-ID or idmapped
mount support, or manage host filesystem ACLs; that ownership mapping cannot be
fixed by publishing another variant of this image.

## Updating Upstreams

Check these sources before changing pins:

- ImageMagick releases:
  `https://api.github.com/repos/ImageMagick/ImageMagick/releases/latest`
- PECL imagick:
  `https://pecl.php.net/rest/r/imagick/latest.txt`
- webdevops PHP Apache tags:
  `https://hub.docker.com/v2/namespaces/webdevops/repositories/php-apache/tags?page_size=100`
- mlocati installer supported extensions:
  `https://raw.githubusercontent.com/mlocati/docker-php-extension-installer/master/data/supported-extensions`

Example version check:

```bash
curl -fsSL https://api.github.com/repos/ImageMagick/ImageMagick/releases/latest \
  | jq -r '.tag_name'
curl -fsSL https://pecl.php.net/rest/r/imagick/latest.txt
curl -fsSL 'https://hub.docker.com/v2/namespaces/webdevops/repositories/php-apache/tags?page_size=100' \
  | jq -r '.results[].name' \
  | grep -E '^[0-9]+\.[0-9]+$'
```

Checksum update helpers for the currently pinned source archives:

```bash
IMAGEMAGICK_VERSION=7.1.2-26
IMAGICK_VERSION=3.8.1
curl -fsSL "https://github.com/ImageMagick/ImageMagick/archive/${IMAGEMAGICK_VERSION}.tar.gz" \
  | shasum -a 256
curl -fsSL "https://pecl.php.net/get/imagick-${IMAGICK_VERSION}.tgz" \
  | shasum -a 256
```

After updating versions, run:

```bash
bash tests/repo_sync_test.sh
bash scripts/repo_sync.sh verify-image-tooling latest
DOCKER_BUILDKIT=1 docker build --pull -f Dockerfile.ubuntu -t php-apache:local .
```

If the local Docker CLI falls back to the legacy builder, use Buildx instead:

```bash
docker buildx build --pull -f Dockerfile.ubuntu .
```

To exercise the same build decision logic used by CI, run the script directly:

```bash
CI_GIT_BRANCH=latest bash scripts/ci/docker_build.sh
CI_GIT_BRANCH=php85 CI_DOCKER_MODE=preflight bash scripts/ci/docker_build.sh
CI_GIT_TAG=8.5 CI_GIT_REF_TYPE=tag CI_DOCKER_MODE=build-publish \
  DOCKER_PASSWORD=... bash scripts/ci/docker_build.sh
```

The promoted publish pipeline runs `scripts/ci/trivy_scan.sh` as a separate
block after `docker push`. It uses `aquasec/trivy:latest` by default. Override
`TRIVY_IMAGE` when testing a different scanner image. The scan is non-blocking,
so a scanner outage or vulnerability finding is reported without failing the
publish job.

GitHub Actions also runs the advisory `Published image analysis` workflow for
version-like tag pushes. It waits for the same Semaphore release status through
`scripts/ci/release_status.sh --wait`, then uses
`scripts/ci/wait_for_published_image.sh` to wait until Docker Hub exposes an
image updated after the tag-push event. It analyzes that exact public tag with
Dive and Docker Scout without rebuilding or publishing it. Dive reports layer
efficiency in the workflow log. Scout reports fixable critical and high
vulnerabilities and base-image recommendations in the job summary, and uploads
SARIF to GitHub code scanning when that feature is available. Operators can
rerun the workflow manually for an existing version tag; manual runs require
the tag to exist but do not require a newer publication. Scanner findings and
SARIF upload failures remain advisory and do not change the completed release.

If the local Docker build is not practical, still run the shell test and review
the Dockerfile diff carefully. The real build happens in Semaphore. After
propagating Dockerfile behavior to supported PHP branches, run
`bash scripts/repo_sync.sh verify-image-tooling` before pushing those branch
updates.

## Downstream Images

The base image intentionally does not bundle application-specific PHP
extensions. It does retain `install-php-extensions` as a supported downstream
customization interface:

```Dockerfile
FROM 1allen/php-apache:8.5

RUN install-php-extensions grpc redis protobuf
```

Pin extension versions downstream when reproducibility matters. Keeping the
extensions themselves in the application image prevents unrelated extension
dependencies and release behavior from becoming part of this base image's
contract.

Install optional operating-system tools by application capability rather than
growing the shared base image:

- image optimization: `jpegoptim`, `webp`;
- media processing: `ffmpeg`;
- database administration: `mariadb-client`.

For example, an application that needs all of the legacy tools can preserve the
old production behavior downstream:

```Dockerfile
FROM 1allen/php-apache:8.5

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        jpegoptim webp ffmpeg mariadb-client \
    && rm -rf /var/lib/apt/lists/*
```

Delete packages the application does not call. Installing `webp` here adds its
CLI tools; the base image already carries the runtime libraries required by its
tested ImageMagick/imagick WebP contract.

## Workflow Change Gate

Use the existing project interface before proposing maintenance or release
machinery:

| Outcome | Maintained interface |
| --- | --- |
| Propagate shared files | `bash scripts/repo_sync.sh sync-shared [--apply\|--push] [--approve-contract-change]` |
| Verify the Dockerfile contract | `bash scripts/repo_sync.sh verify-image-tooling [branches...]` |
| Build or publish an image | `bash scripts/ci/docker_build.sh` through a thin CI adapter |
| Check or wait for release pipelines | `bash scripts/ci/release_status.sh [--wait] [refs...]` |
| Wait for a published Docker Hub tag | `bash scripts/ci/wait_for_published_image.sh [--wait] tag` |
| Scan a published image | `bash scripts/ci/trivy_scan.sh` |
| Review a published image in GitHub | `Published image analysis` Actions workflow |
| Measure published image size | `bash scripts/image_metrics.sh [tags...]` |
| Retire branch-named Docker Hub tags | `bash scripts/docker_hub_cleanup.sh [--apply]` or the manual GitHub Actions workflow |
| Move supported semver tags | `bash scripts/tags_update.sh [--apply] [--approve-contract-change]` |

Before changing external state, preview the exact commands and their branch,
image, tag, or issue effects against the Branch Flow below. Do not replace this
flow with parallel rollout pull requests, temporary rollout branches, duplicate
scripts, or new orchestration unless the maintained interface cannot satisfy a
specific requirement. Document the exact gap and obtain explicit approval
before designing an alternative. If the documented behavior is unclear, inspect
the implementation and ask; do not import a generic workflow.

`scripts/lib/image_contract.sh` is core consumer-contract policy. If it changed,
branch push and tag apply stop by default even when the candidate Dockerfile
passes the new policy. Review the policy diff separately and obtain the user's
explicit approval for that exact change before passing
`--approve-contract-change`. Do not infer this approval from a cleanup, size,
documentation, or dependency-update request.

### Image Size Metrics

Use the registry-compressed linux/amd64 size to evaluate base-image cleanup:

```bash
bash scripts/image_metrics.sh
bash scripts/image_metrics.sh --format tsv 8.0 8.5
```

The protected publish job records provider-neutral build timings and joins them
to the just-published tag in the same job:

```bash
CI_BUILD_METRICS_FILE=/tmp/php-apache-build-metrics.tsv \
  CI_GIT_TAG=8.5 CI_GIT_REF_TYPE=tag CI_DOCKER_MODE=build-publish \
  DOCKER_PASSWORD=... bash scripts/ci/docker_build.sh
bash scripts/image_metrics.sh --build-metrics /tmp/php-apache-build-metrics.tsv
```

The timing record includes cache preparation, Docker build, publish, and total
wall-clock seconds plus the cache refs supplied to BuildKit. Those refs are
cache candidates, not a measured cache-hit rate. The default report remains
size-only when `--build-metrics` is omitted. The post-push combined report is
non-blocking: a Docker Hub reporting delay or outage emits a warning without
changing the completed publication result or preventing the scan.

Build timings remain available in the Semaphore publish-job log. The temporary
TSV joins timings to registry metrics within that job and is not retained as a
separate historical artifact. Run `bash scripts/image_metrics.sh` at any time
for current compressed sizes and baseline comparisons; consult the publish-job
log for the timing report associated with a particular release.

The default report reads supported consumer `X.Y` tags and compares each PHP
line with the immutable pre-cleanup Docker Hub snapshot in
`config/image-size-baseline.tsv`. The snapshot was queried on 2026-07-16 before
PR #6's branch tags were republished, so its historical row keys remain
`phpXX`. Each row preserves the API's prior digest, compressed size, and
`last_updated` value. Positive `Saved` values mean the published image became
smaller. The TSV format emits exact bytes, percentages, current and baseline
digests, and the baseline tag timestamp for release records or further
analysis.

This is a read-only observation interface. It does not build, publish, retag,
pull, or scan images, and size changes are not a release gate. Docker Hub's
compressed size is intentionally different from `docker images` virtual size;
do not mix the two metrics in one comparison.

### Legacy Docker Tag Cleanup

The retired Docker Hub tags have been removed. These were the branch-named tags
`php73`, `php74`, and `php80` through `php85`, together with the floating
`latest` tag. They predated the tag-only publishing policy and were not consumer
interfaces. The maintained cleanup interface now audits and enforces their
continued absence without touching version-like consumer tags.

Use the maintained cleanup interface to read back the exact inventory and
preview its policy-derived deletion set:

```bash
bash scripts/docker_hub_cleanup.sh
```

The dry run lists retired tags that are present, version-like tags that will be
preserved, and any other untouched tags. It does not authenticate or delete.
After confirming the inventory, use one of the two maintained apply adapters.
If a Docker Hub PAT or organization access token is available locally, provide
it through the environment:

```bash
DOCKER_HUB_TOKEN=... bash scripts/docker_hub_cleanup.sh --apply
bash scripts/image_metrics.sh
```

If the deletion-capable PAT is stored as GitHub's protected
`DOCKER_HUB_TOKEN` Actions secret, an operator with write access to the repository
can open **Actions**, select the **Docker Hub cleanup** workflow, select
**Run workflow**, choose the `latest` branch, and confirm **Run workflow**.
Repository administrators maintain the secret; operators can run the workflow
without seeing its value. Review the resulting workflow log for the inventory,
deletions, and final verification. The
`.github/workflows/docker-hub-cleanup.yml` adapter has only a manual
`workflow_dispatch` trigger, refuses any ref other than `refs/heads/latest`,
invokes the same `scripts/docker_hub_cleanup.sh --apply` interface, and prints
the post-delete verification. Do not add `push`, `pull_request`, or `schedule`
triggers to this destructive workflow.

Apply mode obtains a short-lived Docker Hub bearer token, deletes only `latest`
and configured `phpXX` names that are currently present, then inventories the
repository again and fails unless all retired names are absent. The script
refuses to classify `X.Y` or `X.Y.Z` tags as deletion targets. This is a
one-time external cleanup; tag-only CI publishing prevents those names from
being recreated. The workflow is safe to rerun: when no retired tags exist,
the script exits successfully without authenticating or deleting anything.
After either apply adapter succeeds, rerun the local dry run and
`scripts/image_metrics.sh` to verify the final public state.

## Branch Flow

The repository setting should automatically delete merged pull-request head
branches. After closing an unmerged pull request, delete its head branch only
after confirming that the work was intentionally discarded. Use `git fetch
--prune` to remove stale remote-tracking refs; never infer that a remote branch
still exists solely from an unpruned local `origin/*` ref.

1. Make shared changes on `latest`.
2. Confirm shared files are listed in `config/php-branches.conf`.
   `.dockerignore` is shared so build-context hygiene stays consistent.
3. If `Dockerfile.ubuntu` changes, apply the same Dockerfile behavior to each
   `phpXX` branch intentionally. `Dockerfile.ubuntu` is not a shared file
   because each branch can carry a different `FROM webdevops/php-apache:X.Y`
   and extension compatibility pin.
4. For a `latest`-only PR, verify the maintained Dockerfile on the review
   branch:

   ```bash
   bash scripts/repo_sync.sh verify-image-tooling latest
   ```

   After propagating Dockerfile behavior to supported PHP branches, verify every
   committed branch Dockerfile still exposes the expected downstream image
   tooling:

   ```bash
   bash scripts/repo_sync.sh verify-image-tooling
   ```

   This guard exists because documentation on `latest` can advertise a
   downstream customization feature before the semver branches actually include
   the Dockerfile support for it. PHP 7 branches `php73` and `php74` are tracked
   but are not part of the default supported-image guarantee; check them
   explicitly with `bash scripts/repo_sync.sh verify-image-tooling php73 php74`
   when changing those images.
5. Preview branch drift across supported PHP branches:

   ```bash
   bash scripts/repo_sync.sh sync-shared
   ```

6. Apply branch-local sync commits:

   ```bash
   bash scripts/repo_sync.sh sync-shared --apply
   ```

   Deprecated PHP 7 branches are skipped by default. For a critical emergency
   fix only, target them explicitly, for example:

   ```bash
   bash scripts/repo_sync.sh sync-shared php73 php74
   bash scripts/repo_sync.sh sync-shared --apply php73 php74
   ```

7. Run the required final gate, then let the synchronization interface verify
   that no shared-file drift remains and atomically push the complete target
   branch set:

   ```bash
   bash tests/repo_sync_test.sh
   bash scripts/repo_sync.sh verify-image-tooling
   bash scripts/repo_sync.sh sync-shared --push
   ```

   A missing, divergent, or unsynchronized branch fails the push instead of
   leaving a partial rollout. Semaphore runs the release-source preflight but
   does not build or publish Docker images for branch refs.
8. When release image inputs changed, or an explicit rebuild is intended,
   preview and apply Git tag updates for consumer images such as
   `1allen/php-apache:8.2`:

   ```bash
   bash scripts/tags_update.sh
   bash scripts/tags_update.sh --apply
   bash scripts/ci/release_status.sh --wait
   ```

   The status command checks supported version tags by default. It returns `0`
   only when all publish pipelines succeed, `1` when a release fails, `2` for
   pending or timed-out releases, and `3` when status lookup itself fails.

   Do not move version tags after documentation, test, or CI-adapter-only changes.
   In those cases, branch synchronization and its required checks complete the
   rollout. Version-tag movement is a publishing decision, not an automatic
   consequence of advancing the PHP source branches.

   Each pushed version tag runs one cached build in the protected publish
   pipeline, publishes that version-like Docker tag, and then runs the advisory
   scan. This updates supported PHP tags only. Deprecated PHP 7 tags are intentionally
   left where they are unless you name those branches explicitly for a critical
   emergency fix:

   ```bash
   bash scripts/tags_update.sh --apply php73 php74
   ```

## Reviewing Multi-Branch Changes

Keep `latest` as the main review surface for shared files. Review branch-local
Dockerfile changes separately because each `phpXX` branch can preserve a
different base PHP minor or extension compatibility pin.

Useful local review commands:

```bash
git status --short --branch
git diff --stat
git diff
for branch in php80 php81 php82 php83 php84 php85; do
  git log --oneline -1 "$branch"
  git diff "origin/$branch..$branch" -- Dockerfile.ubuntu
done
```

Before pushing, run:

```bash
bash tests/repo_sync_test.sh
bash scripts/repo_sync.sh verify-image-tooling latest
```

Open a PR against `latest` first for shared-file review. Semaphore builds the
PR and the eventual `latest` merge without publishing images. After review,
merge the PR into `latest`, update the local `latest` branch, and run
`bash scripts/repo_sync.sh sync-shared --apply` so the shared-file commits are
created from the merged source branch. After the required checks pass, run
`bash scripts/repo_sync.sh sync-shared --push`; it verifies synchronization and
atomically pushes only the selected `phpXX` branches carrying branch-local
Dockerfile commits plus shared-file sync commits. Semaphore performs preflight
without building or publishing. After those checks pass, use
`scripts/tags_update.sh` to move the supported version tags and trigger one
publish build per version. Leave `php73` and `php74` untouched unless the change
is a critical emergency fix.

For a standalone final gate after branch-local Dockerfile commits and shared
sync commits exist, run:

```bash
bash tests/repo_sync_test.sh
bash scripts/repo_sync.sh verify-image-tooling
```
