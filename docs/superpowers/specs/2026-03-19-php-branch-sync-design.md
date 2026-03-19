# PHP Branch Sync Design

## Summary

This repository keeps one branch per published PHP minor version because the
underlying image, dependency graph, and build steps can diverge over time.
`latest` remains the integration branch for shared maintenance changes, but it
must not assume that every `phpXX` branch is byte-for-byte identical.

## Goals

- Keep the branch-per-version release model.
- Replace the retired Semaphore Ubuntu image with a supported image.
- Add first-class support for PHP `8.5`.
- Make shared-file propagation repeatable from a single command.
- Document the LLM/automation workflow so future refreshes are cheaper.

## Non-Goals

- Converting the repository to a single branch + generated matrix build.
- Auto-merging branch-specific Dockerfile differences without review.
- Creating remote branches or pushing tags automatically as part of the sync
  workflow.

## Current Constraints

- The repo currently has local and remote branches for `php73` through `php84`.
- `.semaphore/semaphore.yml` is effectively shared across branches.
- `Dockerfile.ubuntu` is version-specific and should only be bootstrapped, not
  blindly copied, because older branches already diverge.
- The tag helper should live under `scripts/` with the rest of the repo
  automation rather than as a one-off file at the root.

## Proposed Approach

### Branch Metadata

Store supported PHP branches and shared file paths in a repo-managed manifest.
This makes the maintenance model explicit and gives automation a stable source
of truth instead of hard-coded branch discovery rules.

### Sync Command

Add a script that can:

- show configured and discovered version branches;
- report locally missing branches such as `php85`;
- compare upstream Docker Hub tags with the manifest;
- sync shared files from `latest` into selected local branches using temporary
  git worktrees; and
- bootstrap a new branch by copying `latest` and rewriting the PHP image tag in
  `Dockerfile.ubuntu`.

The script defaults to dry-run behavior and requires `--apply` for mutations.

### CI Updates

Refresh Semaphore to a supported Ubuntu image and keep the build logic aligned
with the current tag/branch release flow. Small hygiene improvements should
favor safety and transparency over introducing a more complex pipeline.

### Documentation

Update `README.md` with:

- the branch model;
- the new sync/bootstrap commands; and
- an explicit note that LLM-assisted maintenance should rely on the manifest and
  sync script instead of ad-hoc manual edits.

## Risks And Mitigations

- Branches can have intentional divergence.
  Mitigation: only sync the files listed as shared in the manifest.
- Automation can accidentally modify the working tree.
  Mitigation: require a clean repo for mutating commands and use temporary
  worktrees for target branches.
- Upstream version discovery can fail due to network issues.
  Mitigation: keep the manifest authoritative and treat remote checks as
  advisory output.

## Success Criteria

- The repo documents how shared changes should be propagated.
- Semaphore config no longer references `ubuntu2004`.
- `latest` can target PHP `8.5`.
- A single command can show drift and optionally sync shared files across local
  PHP branches.
