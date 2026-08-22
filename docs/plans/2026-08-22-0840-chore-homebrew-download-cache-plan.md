---
title: Homebrew Download Cache - Plan
type: chore
date: 2026-08-22
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Homebrew Download Cache - Plan

## Goal Capsule

- **Objective:** the `test-ubuntu` and `test-macos` GitHub Actions jobs reuse Homebrew bottle and cask downloads when a cache hit exists, without caching installed packages or Homebrew metadata.
- **Means:** add `actions/cache@v4` steps immediately after checkout in both test jobs, with platform-specific Homebrew `downloads` paths and rotating primary keys.
- **Authority:** this U2-only plan is scoped by `docs/plans/2026-08-20-2217-chore-ci-workflow-hygiene-plan.md`, U2. That source plan remains the measurement contract for keep-or-revert.
- **Execution profile:** work in an isolated worktree on branch `chore/homebrew-download-cache`.
- **Stop conditions:** revert this cache change if measured cache save plus restore time exceeds the fetch time it removes on either job, or if the Ubuntu and macOS cache entries together exceed half of the 10 GB repository cache budget.

---

## Product Contract

### Summary

Add a Homebrew download cache to the two test jobs in `.github/workflows/test-dotfiles.yml`.
The cache must cover only Homebrew's `downloads` subdirectory.
The cache key must include the runner operating system, the Brewfile source hash, and `github.run_id` so each successful run saves a fresh entry.

### Problem Frame

The CI-minimal Brewfile plan and the Docker-baked Brewfile plan have landed.
That makes U2 safe to attempt last, per the landing order in the source plan.
The remaining bet is narrow: restored Homebrew archives may reduce fetch time, but cache restore and post-job save may cost more than they remove.

### Requirements

**Cache behavior**

- R1. The `test-ubuntu` job restores and saves `~/.cache/Homebrew/downloads` with `actions/cache@v4`.
- R2. The `test-macos` job restores and saves `~/Library/Caches/Homebrew/downloads` with `actions/cache@v4`.
- R3. The primary cache key includes `runner.os`, `hashFiles('home/private_dot_config/brewfiles/Brewfile*')`, and `github.run_id`.
- R4. Restore keys first match the same Brewfile hash for the runner operating system, then fall back to any Brew cache for that runner operating system.

**Safety and scope**

- R5. The cache does not restore the Homebrew cache root, Homebrew API metadata, installed packages, or prefixes.
- R6. A cache miss changes no install behavior and cannot fail the job by itself.
- R7. U1's existing workflow `concurrency` block, triggers, CI-minimal environment selection, and Brewfile-diff full-render override stay unchanged.

**Measurement**

- R8. The pull request records that the cache must be kept only after live GitHub Actions evidence shows net job-duration improvement or acceptable overhead.
- R9. The pull request records the cache budget gate: the two platform cache entries together must stay at or below 5 GB, or U2 is reverted.

### Scope Boundaries

- In scope: two `actions/cache@v4` steps in `.github/workflows/test-dotfiles.yml`.
- Out of scope: changes to Brewfiles, Docker, CI-minimal selection, workflow triggers, `concurrency`, installed-package caching, Homebrew prefix caching, and test suite behavior.
- Deferred to post-merge evidence: the first cache miss, the next cache hit, post-cache save duration, restore duration, cache sizes, and total job-duration comparison.

### Key Decisions

- **Implement only U2.** (session-settled: user-directed — chosen over reworking U1 or sibling plans: U1 is already merged, and the sibling prerequisites have already landed.) Governs R7.
- **Keep the cache measurement-gated.** (session-settled: user-directed — chosen over shipping the cache as a guaranteed optimization: cache overhead can exceed removed fetch time.) Governs R8, R9.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Cache only the Homebrew `downloads` directory.** This follows the source plan's KTD3 and governs R1, R2, and R5. The Homebrew cache root also contains API metadata, aliases, and other state that must not be restored under `HOMEBREW_NO_AUTO_UPDATE: "1"`.
- KTD2. **Use a rotating primary key.** The key shape is `brew-${{ runner.os }}-${{ hashFiles('home/private_dot_config/brewfiles/Brewfile*') }}-${{ github.run_id }}`. This governs R3. A non-rotating key would get an exact restore and skip the post-job save, so newly downloaded archives would not refresh the cache.
- KTD3. **Share one namespace between minimal and full CI modes.** Restore keys use the Brewfile hash and then the operating-system prefix, which lets the nightly full run and minimal push or pull-request runs seed each other. This governs R4. The accepted cost is that a full run may restore a smaller minimal entry and download the rest once.
- KTD4. **Place the cache before every Homebrew install in each test job.** The cache step goes immediately after checkout, before `Validate repository issues` and before any standalone `brew install` step. This governs R1 and R2. The macOS job installs `chezmoi`, `bats-core`, and `fzf` before `chezmoi apply`, so placing the cache later would miss part of the intended fetch path.

### Assumptions

- The precondition is satisfied. `.github/workflows/test-dotfiles.yml` already contains the CI-minimal trigger logic and the event-aware `concurrency` block, and `docker/Dockerfile.ubuntu` already bakes the full Brewfile layer.
- GitHub Actions accepts `~` in the `actions/cache` `path` field for both runner families. This is the existing documented form used by the source plan.

### System-Wide Impact

This change affects GitHub Actions storage and job timing only.
It does not affect local `chezmoi apply`, Docker test runs, live managed files, or the rendered Brewfiles.

### Risks & Dependencies

- **Cache overhead can outweigh fetch savings.** The mitigation is the source plan's keep-or-revert measurement gate.
- **Cache storage can consume too much repository quota.** The mitigation is the 5 GB combined-entry cap in R9.
- **Cancelled or failed jobs do not save the cache.** This is accepted because `actions/cache` saves only on successful jobs, and a miss degrades to today's behavior.

---

## Implementation Units

### U1. Add Homebrew download cache steps

- **Goal:** both test jobs restore Homebrew downloads before any Homebrew install work starts.
- **Requirements:** R1, R2, R3, R4, R5, R6, R7.
- **Dependencies:** none. The prerequisite plans are already visible in the current workflow and Dockerfile.
- **Files:** `.github/workflows/test-dotfiles.yml`.
- **Approach:**
  1. Add a cache step immediately after the `Checkout` step in `test-ubuntu`.
  2. Use `path: ~/.cache/Homebrew/downloads` for `test-ubuntu`.
  3. Add a matching cache step immediately after the `Checkout` step in `test-macos`.
  4. Use `path: ~/Library/Caches/Homebrew/downloads` for `test-macos`.
  5. Use the KTD2 primary key and KTD3 restore keys in both jobs.
  6. Leave all existing workflow steps, comments, triggers, and environment variables unchanged unless formatting is required by YAML.
- **Execution note:** This is workflow configuration. Prefer YAML validation and focused diff review over local test execution that cannot exercise GitHub-hosted cache behavior.
- **Patterns to follow:** the existing workflow uses descriptive comments before behavior that can look surprising; add one short comment if needed to explain why the key rotates.
- **Test scenarios:** Test expectation: none — GitHub Actions cache behavior cannot be proven by local bats or `make` targets.
- **Verification:** the workflow file parses as YAML, and the diff changes only the two cache steps. Live verification happens after a PR or push runs on GitHub Actions.

---

## Verification Contract

| Gate | Command or evidence | Proves |
|---|---|---|
| YAML parses | `python3 - <<'PY'` with `yaml.safe_load(open('.github/workflows/test-dotfiles.yml'))` | The workflow remains syntactically valid YAML. |
| Diff scope | `git diff -- .github/workflows/test-dotfiles.yml` | Only U2 cache steps changed. |
| First live run | GitHub Actions log shows `Cache not found` and both test jobs pass | Cache miss degrades to current behavior. |
| Second live run | GitHub Actions log shows a restore in both test jobs | Restore keys can find the previous entry. |
| Cache freshness | The `Post Cache` step saves a fresh entry instead of skipping due to exact primary-key restore | The rotating key works. |
| Net timing | `gh run view <run-id> --json jobs` for the baseline, miss run, and hit run | Cache restore plus save overhead does not exceed fetch time removed on either job. |
| Cache budget | GitHub Actions cache list for the two platform entries | The combined entry size stays at or below 5 GB. |

---

## Definition of Done

- `.github/workflows/test-dotfiles.yml` contains an `actions/cache@v4` download-cache step in `test-ubuntu` immediately after checkout.
- `.github/workflows/test-dotfiles.yml` contains an `actions/cache@v4` download-cache step in `test-macos` immediately after checkout.
- The cache key and restore keys match KTD2 and KTD3 exactly.
- No non-U2 workflow behavior changes.
- Local YAML validation passes.
- The pull request states that U2 remains provisional until live cache timing and cache-size evidence clears R8 and R9.
- If live evidence fails R8 or R9, U2 is reverted and that result is reported as a valid completion.
