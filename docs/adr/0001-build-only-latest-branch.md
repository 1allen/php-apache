# Build Only From Latest Branch

The `latest` branch is the integration branch for shared maintenance changes,
not a consumer PHP version line. CI should build PR branches and `latest` to
prove the image still builds, but Docker Hub publishing belongs to `phpXX`
branches and semver git tags so published image names stay tied to the
project's existing branch and tag model.

