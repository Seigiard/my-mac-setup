---
title: CI Workflow Hygiene - Plan
type: chore
date: 2026-08-20
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# CI Workflow Hygiene - Plan

## Goal Capsule

- **Objective:** the newest commit's CI verdict arrives sooner, and stale superseded runs stop holding macOS runner slots. `Seigiard/my-mac-setup` is a **public** repository, so standard GitHub-hosted runners (`ubuntu-latest`, `macos-latest`) are unmetered — this plan saves **no money**, and any framing that claims otherwise is wrong. The payoff is feedback latency and runner-slot contention. Secondarily, Homebrew archive re-downloads shrink when a cache restores them; that fetch-time shrink is U2's verification signal, while deliberate install-latency work lives in the sibling CI-minimal-brew-install and Docker-baked-Brewfile plans of the same date.
- **Means:** a workflow `concurrency` block with `cancel-in-progress` (KTD1, KTD2) and `actions/cache` for the Homebrew download directories (KTD3).
- **Authority:** this plan.
- **Stop conditions:**
  - U1 (concurrency) has none — additive YAML, trivially revertible.
  - U2 (cache) reverts if the measured cache save plus restore time exceeds the fetch time it removes on either job, or if the two platform entries together consume more than half the 10 GB per-repository cache budget. U2 is a measured bet, not a given; see KTD5.

---

## Product Contract

### Summary

Add a `concurrency` group to `.github/workflows/test-dotfiles.yml` that cancels a superseded run when a newer commit arrives on the same ref **via the same event type** (`push` or `pull_request`), including pushes to `main`, so a scheduled run on `main` is never cancelled by a push. Add `actions/cache` steps for the Homebrew **download** directories in both test jobs, keyed on the Brewfile hashes plus a rotating run component.

### Problem Frame

**Superseded runs.** The workflow has no `concurrency` block, so a run keeps going after a newer commit supersedes it. Measured on 2026-08-20 (`gh run list --branch main`): of 16 `main` runs that day, **5 were still in flight when a newer push arrived** — 04:20:20, 04:24:29, 08:55:50, 16:41:10, and 20:03:32. Cancellation reclaims only each one's *remaining* time, roughly 43 minutes of run wall time across the whole day, not five full runs. Every other push's run had already finished before the next push landed. The value is that the newest commit's verdict is not queued behind a run nobody will read, and that macOS runner slots free up sooner.

**Repeated downloads.** Every run re-downloads brew bottles and casks. Run 32393379268 shows `Apply dotfiles` taking **6 min 42 s on macOS** and **3 min 36 s on Ubuntu**, with fetch blocks of 30+ s inside it (`Fetching elio, terminal-notifier, claude-code, font-jetbrains-mono-nerd-font, …`). Downloads are the cacheable part of install time; unpack and link are not.

### Requirements

- R1. A new push to a ref cancels that ref's in-progress workflow run, for pull requests and for `main`.
- R2. A nightly scheduled run (added by the CI-minimal-brew-install plan) and a push run never cancel each other.
- R3. Both test jobs restore and save the platform's Homebrew download directory, keyed on the Brewfiles' content hash, and every run that completes successfully saves an updated entry rather than pinning the first one forever.
- R4. Cache misses degrade to today's behavior (full download), never to a failed run.
- R5. The cache measurably reduces total job duration, or it is reverted (see Stop conditions).

### Scope Boundaries

- Not in scope: caching installed packages themselves (pour/link time) — the install-time levers live in the CI-minimal-brew-install plan and the Docker-baked-Brewfile plan of the same date.
- Not in scope: the `lint` job — it installs one apt package in ~3 s; caching would add more YAML than it saves.
- **Landing order — this plan straddles the chain; its two units land at opposite ends.** Order settled 2026-08-21 in `docs/issues/2026-08-21-002-perf-plan-landing-order-undecided.md`: U1 (the `concurrency` block) is **first** of the four plans' work — it depends on nothing and is trivially revertible. U2 (the Homebrew download cache) is **last**, after the CI-minimal-brew-install plan and the Docker-baked-Brewfile plan, per KTD5. Do not land U1 and U2 together. The parallel-bats plan also edits `.github/workflows/test-dotfiles.yml`; re-diff against it if it lands between the two units.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **`cancel-in-progress: true` applies to `main` pushes, not only PRs.** (session-settled: user-approved — chosen over protecting `main` runs from cancellation: for this repo only the newest commit's green matters; a cancelled superseded run on `main` loses nothing.) Verified consequence: `main` carries no branch protection and no rulesets, so a cancelled run blocks no required check. The accepted cost is that a superseded `main` commit ends with no CI verdict, which makes a later bisect over those commits less informative.

- KTD2. **The concurrency group includes the event name: `${{ github.workflow }}-${{ github.event_name }}-${{ github.ref }}`.** A nightly `schedule` run executes on `refs/heads/main`, the same ref as pushes; without `event_name` in the group, a morning push would cancel the running nightly full-Brewfile run (or vice versa), silently dropping the full-install verification (R2). A cancelled run sends no failure notification, so that loss would be silent. This decision anticipates the schedule trigger from `docs/plans/2026-08-20-2217-perf-ci-minimal-brew-install-plan.md` and is harmless before it lands. **R2 is not verifiable when this plan lands** — see the hand-off in the Definition of Done.

- KTD3. **Cache the Homebrew `downloads/` subdirectory, keyed on Brewfile hashes plus a rotating run component.**
  - Paths: `~/Library/Caches/Homebrew/downloads` (macOS job), `~/.cache/Homebrew/downloads` (Ubuntu job). Deliberately **not** the Homebrew cache root: the root also holds `api/` (formula and cask JSON metadata), `bootsnap/`, and alias symlinks. Restoring `api/` would make CI resolve formulae against stale restored metadata, because the workflow already sets `HOMEBREW_NO_AUTO_UPDATE: "1"` — a behavior change the Definition of Done says it does not want.
  - Key: `brew-${{ runner.os }}-${{ hashFiles('home/private_dot_config/brewfiles/Brewfile*') }}-${{ github.run_id }}`.
  - Restore keys, in order: `brew-${{ runner.os }}-${{ hashFiles('home/private_dot_config/brewfiles/Brewfile*') }}-` then `brew-${{ runner.os }}-`.
  - The rotating `github.run_id` is load-bearing, not decoration. `actions/cache` skips its post-job save whenever the restore was an exact primary-key match, so a key built only from the Brewfile hash is written **once** and never refreshed — newly downloaded archives (after a runner-image bottle bump, or from a nightly full-Brewfile run) would never be persisted. Rotating the primary key makes every successful run save an updated entry while the restore keys still find the newest matching one.
  - Chosen over caching the Homebrew prefix (installed packages): the prefix is large, version-brittle, and interferes with `brew bundle`'s own state; the download directory is the safe, self-validating layer (brew checksums every archive it reads from cache).

- KTD4. **Push/PR runs and the nightly full run share one cache namespace; the rotating key is what makes sharing work.** Once the CI-minimal plan lands, push/PR runs install only a minimal subset. Both modes hash the same Brewfile sources, so they compute the same hash component — the rotating run component is what stops whichever mode runs first from pinning the entry forever, and the restore keys let each mode inherit the other's archives. The accepted cost: a nightly full run restores a minimal run's smaller entry and re-downloads the rest, then saves the full set. No per-mode key namespace for now; revisit if the nightly run's fetch time does not fall (see KTD5).

- KTD5. **U2 (the cache) is measurement-gated and lands after the CI-minimal-brew-install plan.** (session-settled: user-approved — chosen over deleting U2 outright once the Actions-minutes cost premise proved void on a public repo: the cache may still pay off on the nightly full-Brewfile run, so it is measured rather than assumed or discarded.) Order: CI-minimal first, then re-measure, then U2. Reason: that sibling plan cuts push/PR installs to roughly seven packages, which removes most of the download volume U2 exists to cache — so U2 measured before it would be sized against a baseline that is about to disappear, and the residual win would sit almost entirely on the nightly full run. U1 (concurrency) has no such dependency and can land immediately. U2 is kept only if the Stop conditions clear it; reverting U2 on the measurement is a valid outcome, not a failure.

---

## Implementation Units

### U1. Concurrency block

- **Goal:** superseded runs cancel automatically; nightly and push runs stay independent.
- **Requirements:** R1, R2.
- **Dependencies:** none. Can land immediately, ahead of every sibling plan.
- **Files:** `.github/workflows/test-dotfiles.yml`.
- **Approach:** add a top-level `concurrency` block with the KTD2 group expression and `cancel-in-progress: true`.
- **Test scenarios:** `Test expectation: none — workflow YAML; verification is observing live runs.`
- **Verification:** open a PR from a branch, then push two commits to it in quick succession (the workflow's `push` trigger fires only for `main`; branch pushes reach CI only through `pull_request` events, whose runs share one concurrency group) — `gh run list` shows the first run `cancelled`, the second running. Then push two commits to `main` in quick succession and confirm the first `main` run also shows `cancelled`, since R1 covers both paths and only the PR path would otherwise be observed. A `workflow_dispatch`/scheduled run (once the trigger exists) is not cancelled by a push.

### U2. Homebrew download cache in both test jobs

- **Goal:** brew fetch time drops on cache-hit runs; misses change nothing; the cache is reverted if it does not pay for itself.
- **Requirements:** R3, R4, R5.
- **Dependencies:** KTD5 — land after the CI-minimal-brew-install plan and re-measure first.
- **Files:** `.github/workflows/test-dotfiles.yml`.
- **Approach:** in `test-ubuntu` and `test-macos`, immediately after the checkout step (not merely "before the apply" — the macOS job's standalone `brew install chezmoi|bats-core|fzf` steps should also read from the cache), add `actions/cache@v4` with the platform's `downloads` path from KTD3, the KTD3 rotating key, and the two restore keys. The glob `Brewfile*` survives the later `.tmpl` rename the CI-minimal plan makes.
- **Known limitation, accepted:** `actions/cache` declares `post-if: success()`, so a job that fails or is cancelled saves nothing. Every run U1 cancels contributes no cache, and a failing PR that edits a Brewfile re-downloads the whole new key's archives on each retry. This is consistent with R4 (degrade to today's behavior) and is not worked around.
- **Patterns to follow:** step ordering and comment style of the existing workflow.
- **Test scenarios:** `Test expectation: none — workflow YAML.`
- **Verification:** first post-merge run shows `Cache not found` and still passes; the next run shows a restore. Record the size and duration the `Post Cache` step reports on each job. Compare **total job duration** (job `startedAt` to `completedAt` via `gh run view <id> --json jobs`) between the pre-cache baseline and a cache-hit run — not apply-step timings alone, because the cache restore and post-job save sit outside the apply step and are exactly what could make the job slower.

---

## Verification Contract

| Gate | Command | Proves |
|---|---|---|
| Workflow still valid | open a PR (or push to main), run completes | YAML correctness |
| Cancellation, PR path | two quick pushes to an open PR → `gh run list` shows first cancelled | R1 |
| Cancellation, main path | two quick pushes to `main` → `gh run list` shows first cancelled | R1 |
| Nightly isolation | scheduled run survives a concurrent push (deferred; see Definition of Done) | R2 |
| Cache refreshes | second post-merge run's `Post Cache` step saves a new entry rather than reporting an exact-key hit | R3 |
| Cache-miss safety | first run on a new key shows `Cache not found` and the job still passes | R4 |
| Cache pays off | total job duration on a cache-hit run vs. the run 32393379268 baseline (macOS apply 6 min 42 s, Ubuntu apply 3 min 36 s; macOS job 14 min 13 s, Ubuntu job 8 min 39 s) | R5 |

## Definition of Done

- `concurrency` block live with the event-aware group; superseding observed once on a real pair of PR pushes **and** once on a real pair of `main` pushes.
- Both test jobs restore and save the Homebrew download directory; one cache-hit run observed, and its `Post Cache` step confirms a fresh save rather than an exact-key skip.
- Total job duration on a cache-hit run is measurably lower than the baseline above on at least one job. If it is not, U2 is reverted per the Stop conditions — reverting is a valid completion, not a failure.
- **R2 remains unverified when this plan lands**, because no `schedule` or `workflow_dispatch` trigger exists yet. Hand-off recorded: the CI-minimal-brew-install plan's unit that wires the workflow trigger must confirm a scheduled or dispatched run survives a concurrent push before that plan's Definition of Done is met.
- No other workflow behavior changed (step list and triggers otherwise identical).
