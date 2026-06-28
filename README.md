# php-apache

Custom `webdevops/php-apache` images with a newer ImageMagick build, bundled
PECL `imagick`, WebP support, and the mlocati `install-php-extensions` helper
kept inside the final image for downstream customization.

`latest` is the integration branch for shared maintenance. Published PHP images
live on `phpXX` branches and version-like git tags.

## Documentation

- [docs/README.md](docs/README.md): documentation map, sources of truth, and glossary
- [docs/maintenance.md](docs/maintenance.md): update, branch propagation, and release runbook
- [docs/decisions.md](docs/decisions.md): durable project decisions
- [AGENTS.md](AGENTS.md): agent-specific guardrails

## Quick Commands

```bash
bash scripts/repo_sync.sh status
bash tests/repo_sync_test.sh
bash scripts/repo_sync.sh verify-image-tooling latest
```

After Dockerfile behavior has been propagated to supported PHP branches:

```bash
bash scripts/repo_sync.sh verify-image-tooling
```

## Downstream Extension Installs

```Dockerfile
FROM 1allen/php-apache:8.5

RUN install-php-extensions protobuf grpc redis
```
