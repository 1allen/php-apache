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

## Stage ImageMagick With DESTDIR

ImageMagick should be configured with its runtime prefix as `/usr/local` and
installed into a temporary staging root with `make install DESTDIR=/tmp/imgck`.
This keeps copied artifact paths aligned with their runtime location while still
allowing the final image to copy only the staged `/usr/local` tree from the
builder stage.
