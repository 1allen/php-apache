# PHP Branch Sync Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refresh CI and branch metadata for current upstream support while adding a repeatable command for syncing shared repo changes across PHP version branches.

**Architecture:** Keep the existing branch-per-version model and introduce a small manifest plus shell automation to handle shared-file propagation and new-version bootstrap tasks. The implementation stays bash-first so the repo remains easy to run in minimal CI or local environments.

**Tech Stack:** Bash, git worktree, Semaphore CI YAML, Markdown docs

---

### Task 1: Document the approved design

**Files:**
- Create: `docs/superpowers/specs/2026-03-19-php-branch-sync-design.md`
- Create: `docs/superpowers/plans/2026-03-19-php-branch-sync.md`

- [ ] **Step 1: Save the approved design**

Write the validated branch-sync design into the specs directory.

- [ ] **Step 2: Save the implementation plan**

Write this plan into the plans directory for future execution/reference.

### Task 2: Add a failing shell test for sync automation

**Files:**
- Create: `tests/repo_sync_test.sh`
- Test: `tests/repo_sync_test.sh`

- [ ] **Step 1: Write the failing test**

Create a bash test that expects the new sync script to support `status`,
`bootstrap-version --dry-run`, and shared-file listing via the manifest.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/repo_sync_test.sh`
Expected: FAIL because `scripts/repo_sync.sh` and the manifest do not exist yet.

- [ ] **Step 3: Write minimal implementation**

Create the manifest and script so the test can pass without over-generalizing.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/repo_sync_test.sh`
Expected: PASS

### Task 3: Refresh CI and shared tooling

**Files:**
- Modify: `.semaphore/semaphore.yml`
- Modify: `scripts/tags_update.sh`
- Modify: `README.md`
- Create: `scripts/repo_sync.sh`
- Create: `config/php-branches.conf`

- [ ] **Step 1: Update Semaphore image settings**

Move off `ubuntu2004` and keep the pipeline behavior aligned with the current
release flow, including php branch builds.

- [ ] **Step 2: Add the sync/bootstrap script**

Implement manifest-driven dry-run/apply behavior using temporary worktrees.

- [ ] **Step 3: Align the legacy tag helper**

Make `tags_update.sh` delegate to the new manifest-aware branch list.

- [ ] **Step 4: Update the docs**

Document the branch model, new commands, and the intended LLM-assisted refresh
workflow.

### Task 4: Verify the repository changes

**Files:**
- Test: `tests/repo_sync_test.sh`
- Test: `.semaphore/semaphore.yml`
- Test: `scripts/repo_sync.sh`
- Test: `scripts/tags_update.sh`

- [ ] **Step 1: Run the shell regression test**

Run: `bash tests/repo_sync_test.sh`
Expected: PASS

- [ ] **Step 2: Run shell syntax checks**

Run: `bash -n scripts/repo_sync.sh scripts/tags_update.sh tests/repo_sync_test.sh`
Expected: exit `0`

- [ ] **Step 3: Inspect the sync script output**

Run: `bash scripts/repo_sync.sh status`
Expected: supported branches, local branches, and shared files are reported.

- [ ] **Step 4: Inspect the final diff**

Run: `git diff -- . ':(exclude).idea'`
Expected: only the intended repo docs/config/script changes are present.
