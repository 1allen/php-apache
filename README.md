# php-apache
custom `webdevops/php-apache` with latest imagemagick &amp; imagick with webp support on board.

`latest` is the integration branch for shared maintenance updates. Published PHP
versions continue to live on their own `phpXX` branches because the Docker build
steps can diverge by version.

## Branch model

- `latest`: integration branch for shared repo changes
- `php80`-`php85`: actively supported version branches
- `php73`-`php74`: legacy version branches still tracked in the manifest

FYI the `latest` branch contains the latest changes, not necessarily the latest
PHP branch history.

## Maintenance commands

Check the current repo and upstream state:

```bash
bash scripts/repo_sync.sh status
```

Preview shared-file drift from `latest` into all local PHP branches:

```bash
bash scripts/repo_sync.sh sync-shared
```

Apply that shared-file sync as branch-local commits:

```bash
bash scripts/repo_sync.sh sync-shared --apply
```

Preview a new PHP branch bootstrap from `latest`:

```bash
bash scripts/repo_sync.sh bootstrap-version php85
```

Create the new local branch and seed its first commit:

```bash
bash scripts/repo_sync.sh bootstrap-version php85 --apply
```

Preview Docker tag updates for configured branches:

```bash
bash scripts/tags_update.sh
```

Push those tag updates:

```bash
bash scripts/tags_update.sh --apply
```

## LLM / automation notes

- Treat `config/php-branches.conf` as the source of truth for supported branches
  and shared files.
- Put shared maintenance changes on `latest` first, then use
  `bash scripts/repo_sync.sh sync-shared` to preview branch drift.
- Use `bootstrap-version` when upstream adds a new PHP minor tag so the repo has
  a predictable, reviewable starting point for that branch.
- Remote checks in `status` are advisory; the manifest stays authoritative if a
  network lookup is unavailable.
