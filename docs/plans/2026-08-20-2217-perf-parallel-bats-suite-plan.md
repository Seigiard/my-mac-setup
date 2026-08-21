---
title: Parallel Bats Suite - Plan
type: perf
date: 2026-08-20
status: done
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Parallel Bats Suite - Plan

> **Shipped 2026-08-21** in `543ca9e` (PR #29). Delivered: the post-apply suite
> runs `bats --jobs 8 --no-parallelize-across-files` in both CI jobs, both Docker
> compose services, and `make test-suite`. On the merged tree CI measures 160 s
> on Ubuntu and 275 s on macOS. Ubuntu meets the 60%-of-baseline gate; macOS
> lands at 65% and invoked the plan's *stable but slow* stop condition, filed as
> `docs/issues/2026-08-21-012-macos-suite-misses-the-60-percent-wall-time-gate.md`.
> Residuals from the review are filed as issues 013, 014 and 015 of the same day.

## Goal Capsule

- **Objective:** the post-apply bats suite (330 tests at HEAD) finishes at ≤ 60% of its measured baseline wall time on both CI jobs, without introducing flakes. Ubuntu's baseline is 268 s, so the Ubuntu gate is ≤ 161 s. **macOS has no valid baseline yet:** the run this plan originally cited (32393379268) failed on the macOS post-apply step itself, so its 416 s figure times an aborted suite, not a passing one. U0 re-measures macOS before that gate is set. Local and Docker runs gain from the same mechanism but are not gated on wall time (KTD5).
- **Means:** `bats --jobs` with cross-file parallelism disabled (KTD1), per-file serialization opt-outs where needed (KTD2).
- **Authority:** this plan. Prerequisite **partly** met: issue `docs/issues/2026-08-20-002` is fixed. Issue `docs/issues/2026-08-20-010` closed with one test fixed and its socket-namespace test closed **unreproduced, with nothing changed** — that flake surface is still open. 010 records that CPU saturation alone did not reproduce it because "the full suite's process and file-descriptor contention is a different profile", which is exactly the profile within-file parallelism intensifies. U4 therefore carries 010's capture protocol.
- **Stop conditions:**
  - *Unattributable instability outside `tests/scripts.bats`.* If U4 shows new failures that only occur under parallelism and U1's audit cannot attribute them to a fixable shared resource, reduce scope to parallelizing `tests/scripts.bats` only, and file the findings in `docs/issues/`.
  - *Instability inside `tests/scripts.bats`.* U4's per-file serialization rule wins over the fallback above; the two must not be applied to the same event. Serializing `tests/scripts.bats` forfeits 85% of the available gain (Problem Frame), so that branch abandons the wall-time gate outright: record the achieved time, file the residual in `docs/issues/`, and stop.
  - *Stable but slow.* If every U4 repetition is green and the suite still lands above 60% of baseline, do not block. Accept the achieved gain, record the measured job-count curve and the achieved ratio as this plan's delivered result, and file the remaining gap in `docs/issues/` as the trigger for the deferred cross-file work.

---

## Product Contract

### Summary

Run the bats suite with N parallel jobs inside each file while keeping files sequential. Nearly all the available gain sits in one file, `tests/scripts.bats` (85% of the Ubuntu baseline), so the work is scoped around that file first. Confirm the within-file locking primitive bats actually needs (`flock` / `shlock`), measure the job count rather than deriving it from core count, then audit shared-state hazards and serialize the few files that must stay sequential.

### Problem Frame

The post-apply suite is 330 tests at HEAD (322 at the measured run). Sequential execution is the bottleneck, and per-test optimization cannot pay — the time is fork/exec overhead and short polling sleeps spread across hundreds of tests.

**The time is not spread evenly across files.** Per-file wall times, derived from the Ubuntu job log of CI run 32393379268 (job 96504504962) by differencing the TAP completion timestamps at each file boundary:

| File | Wall time | Share | Tests | Per test |
|---|---:|---:|---:|---:|
| `tests/scripts.bats` | 228.3 s | 85.2% | 186 | 1.23 s |
| `tests/palette.bats` | 24.4 s | 9.1% | 56 | 0.44 s |
| `tests/smoke.bats` | 13.0 s | 4.9% | 70 | 0.19 s |
| `tests/idempotent.bats` | 1.3 s | 0.5% | 4 | 0.32 s |
| `tests/platform.bats` | 0.9 s | 0.3% | 6 | 0.15 s |
| **Total** | **267.9 s** | | **322** | 0.83 s |

Three consequences follow, and they shape the whole plan:

1. **`tests/scripts.bats` is the only file that matters.** Everything else totals 39.6 s (14.8%). Reaching the ≤ 161 s Ubuntu gate requires cutting 107 s, and perfect parallelism on the other four files can supply at most ~30 s of it. The audit and the measurement both start there.
2. **The serial floor R3 preserves is negligible.** `tests/idempotent.bats` — the file whose shared-`$HOME` mutation motivates KTD1 and R3 — is 1.3 s, half a percent of the baseline. Serializing it unconditionally costs nothing measurable.
3. **The 0.83 s/test average is misleading.** `tests/scripts.bats` runs at 1.23 s/test while every other file runs at 0.15–0.44 s/test.

**The job count is bounded by a poll, not by cores.** Bats does not dispatch on slot release: `bats_semaphore_acquire_slot` in `lib/bats-core/semaphore.bash` busy-waits with a literal `sleep 1` between free-slot checks (the source carries a `TODO` acknowledging it). Whenever all slots are busy, the dispatcher idles up to a full second before noticing one freed. Throughput is therefore capped near `--jobs` tests per second, and oversubscribing past core count is close to free because the limiter is wall-clock polling rather than CPU. This is why KTD3 sets the job count by measurement rather than by core count. Runners have 4 cores (Ubuntu) / 3 cores (macOS arm); local machines have more (10 on the primary host).

**macOS has no usable baseline.** The macOS job of run 32393379268 **failed**, and it failed on the post-apply tests step itself (16:48:22 → 16:55:22). The 416 s figure earlier drafts of this plan used as the macOS baseline therefore times a suite that aborted, not one that passed. U0 establishes a real macOS baseline from a green run before any macOS gate is set.

Bats ≥ 1.5 supports `--jobs N`; the repo runs Bats 1.14 locally, apt bats 1.10.0 on the CI Ubuntu runner, and current bats-core via brew in Docker. All three support `--jobs` and `--no-parallelize-across-files`.

### Requirements

**Invocation coverage**

- R1. The post-apply suite runs with parallel jobs in CI (both jobs), in Docker (`test-full`, `test-quick` services), and through a `make` target locally. Local parallelism is a working default, not documentation: a developer who runs the repo's own test command gets the parallel form without remembering flags.
- R2. Test files execute sequentially relative to each other; parallelism happens within a file.
- R5. The within-file locking primitive bats requires — `flock` or `shlock` — is present on every runtime that runs the suite with `--jobs`, and each runtime asserts it before the first parallel run.

**Correctness and stability**

- R3. Files whose tests mutate shared state (at minimum `tests/idempotent.bats`, whose tests run real `chezmoi apply` against the shared `$HOME`) execute their tests sequentially even in a parallel run. This costs 1.3 s of the 268 s Ubuntu baseline, so it is not a speed trade-off.
- R4. The parallel suite shows no failures across U4's repetitions on either CI job or in the CPU-limited container. Stated as an absolute gate rather than a comparison against the sequential suite: U4 collects no sequential control arm, so "at least as stable as sequential" would not be evidenced by the data the plan gathers.

**Speed**

- R6. The post-apply suite's CI step wall time is ≤ 60% of the measured baseline on both jobs: ≤ 161 s on Ubuntu (268 s baseline), and ≤ 60% of the macOS baseline U0 establishes. Missing this threshold with a stable suite is not a failure — the Goal Capsule's *stable but slow* stop condition governs that outcome.

### Scope Boundaries

- Not in scope: making individual tests faster (shortening polling sleeps, reducing stub setup cost) — separate optimization if parallel gains prove insufficient.
- Not in scope: parallelizing `tests/templates.bats` (the pre-apply gate takes ~5 s; not worth risk).
- Not in scope: splitting `tests/scripts.bats` into smaller topic files. It would make cross-file parallelism viable later, but KTD1 settles the within-file approach for this plan.
- **Deferred to Follow-Up Work:** cross-file parallelism (would need `$HOME`-mutation isolation for `idempotent.bats` and an audit of cross-file fixture sharing); revisit only if within-file parallelism under-delivers. If it is ever adopted, GNU parallel becomes a genuine runtime dependency and the provisioning this plan removes must come back.
- **Landing order — this plan is order-free.** The order across the four same-date plans was settled 2026-08-21 in `docs/issues/2026-08-21-002-perf-plan-landing-order-undecided.md`: CI-workflow-hygiene `concurrency` block, then CI-minimal-brew-install, then Docker-baked-Brewfile, then the CI-workflow-hygiene download cache. This plan sits outside that chain and can land at any point in it.

  Dropping the GNU parallel provisioning (KTD4) is what removed it from the chain: U2 no longer touches `home/private_dot_config/brewfiles/Brewfile` or `docker/Dockerfile.ubuntu`, so the Brewfile rename in the CI-minimal plan and the baked `brew bundle` layer in the Docker plan are both irrelevant here. Two overlaps remain and are re-diffs, not orderings: `.github/workflows/test-dotfiles.yml` also carries the hygiene plan's `concurrency` block, and the `command` blocks this plan edits in `docker/docker-compose.yml` sit beside the `build` keys the Docker plan edits and the `MMS_CI_MINIMAL` entry the CI-minimal plan adds. Field-disjoint in all three cases.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **`--jobs N --no-parallelize-across-files`: parallel within a file, files sequential.** (session-settled: user-approved — chosen over full cross-file parallelism: `tests/idempotent.bats` mutates the shared `$HOME` via real `chezmoi apply` while other files read deployed files from it; cross-file interleaving is unsafe without a bigger refactor.) `tests/scripts.bats` holds 194 of the 330 tests and its tests are stub-isolated in per-test temp dirs, so the dominant file parallelizes well. The measured split confirms this is where the decision pays: that one file is 85% of the Ubuntu baseline (Problem Frame).
- KTD2. **Per-file serialization via `BATS_NO_PARALLELIZE_WITHIN_FILE=true`, set at file scope in unsafe files.** Bats honors this variable per file; it keeps the opt-out next to the code that needs it instead of in the runner invocation. `tests/idempotent.bats` gets it unconditionally (R3); U1's audit decides the rest.
- KTD3. **Job count is set by measurement, not by core count.** Bats' dispatcher polls on a one-second sleep (Problem Frame), so within-file throughput is bounded near `--jobs` tests per second and oversubscribing past core count costs little. Sizing to cores optimizes the wrong axis: on a 4-core runner at `--jobs 4`, short tests can show no speedup at all. U0 measures Ubuntu wall time at 4, 8, and 12 jobs and the plan adopts the best value as a fixed literal in CI, Docker, and the local `make` target. **Measured, and settled at `--jobs 8`** — see *U0 Results* below. 12 is 2.5% faster than 8 on Ubuntu but both slower and materially less stable on the 3-core macOS runner, so 8 is the single literal. A fixed literal is still preferred over a dynamic `nproc` expression — `nproc` is coreutils-only and coreutils is not in the Brewfile, so the dynamic form would not work on a freshly provisioned macOS host.
- KTD4. **The runtime dependency is `flock` / `shlock`, not GNU parallel — nothing needs installing.** Bats shells out to `parallel` only on the cross-file branch, guarded by `[[ -z "$bats_no_parallelize_across_files" ]]` in `libexec/bats-core/bats-exec-suite`. KTD1's `--no-parallelize-across-files` takes the other branch, so `parallel` is never invoked. Within-file parallelism runs on bats' own semaphore, which requires `flock` or `shlock` and hard-exits with `ERROR: flock/shlock is required for parallelization within files!` when neither is present. Verified empirically: on a macOS host with no `parallel` installed, `bats --jobs 4 --no-parallelize-across-files` runs clean while the same command without the flag dies with `parallel: command not found`. `flock` ships in ubuntu:22.04 (the Docker base) and ubuntu-24.04; macOS has no `flock` but ships `/usr/bin/shlock`. So no package is needed on any target — U2 asserts presence instead of installing. (Ubuntu's apt `bats` also already lists `parallel` under Recommends, making the apt step redundant twice over.)
- KTD5. **CI step wall time is the only enforced speed gate.** Docker and local runs prove stability, not speed. `make test-ubuntu` runs the compose `test-quick` service end to end — source copy, `chezmoi init`, `tests/templates.bats`, a full `chezmoi apply` including `brew bundle`, then the suite — so container wall time is dominated by the apply, and nothing in `docker/docker-compose.yml` times the bats call separately. There is no comparable number to measure against the CI step baselines, so the plan does not pretend to gate on one.

### Assumptions

- The known flake surface holds under higher load. Issue `2026-08-20-010` documented two tests flaking under full-suite load; one was fixed, the other closed unreproduced with nothing changed (Goal Capsule — Authority). Within-file parallelism raises exactly the contention profile 010 named. U4's repetitions are the check; a recurrence is a test bug to fix and a reason to reopen 010, not a reason to abandon parallelism (the stop conditions govern the exceptions).
- `mktemp`-based temp paths in `tests/scripts.bats` and `BATS_TEST_TMPDIR` usage elsewhere provide sufficient per-test isolation. Partly verified already: no `setup_file` / `teardown_file` / `$BATS_SUITE_TMPDIR` usage exists anywhere in `tests/*.bats`; `tests/scripts.bats` has zero `$HOME` references and builds all state under `mktemp -d`; the lock at `tests/scripts.bats:1095` already lives under a per-test `mktemp -d`; and `CHEZMOI_TEST_CONFIG` in `tests/helpers/common.bash` is referenced only by `chezmoi_test_init()`, which no `.bats` file calls. U1's audit surface is therefore smaller than earlier drafts of this plan assumed.
- `BATS_NO_PARALLELIZE_WITHIN_FILE=true` at file scope is honored. Verified: bats sources a file's free code in `bats_run_setup_file` before `bats_run_tests` reads the variable, and an empirical run showed four one-second tests taking 4.3 s with the flag versus 1.4 s without, on both bats 1.10.0 and 1.14.0.

---

## U0 Results (measured 2026-08-21)

All figures are the `Run post-apply tests` step, CI run `32435170556`, throwaway
branch `perf-measure-jobcount`. Each job measured its own sequential control, so
the comparisons below are same-machine and carry no runner-to-runner variance.

### Baselines, from a green control in the same job

| Job | Sequential control | 60% gate |
|---|---:|---:|
| Ubuntu (4 cores) | **272 s** | 163 s |
| macOS (3 cores) | **379 s** | 227 s |

The macOS baseline replaces the 416 s figure earlier drafts used, which timed an
**aborted** suite (run `32393379268` failed on the post-apply step itself). The
Ubuntu control of 272 s is consistent with the plan's stated 268 s baseline.

Run-to-run variance is real and worth recording: three consecutive green runs on
`main` measured the Ubuntu step at 199 s, 236 s and 271 s, and macOS at 340 s,
367 s and 447 s. That is why the gate is judged against a control measured in
the same job rather than against a figure from another run.

### Job-count curve, three repetitions each

| Config | Ubuntu | macOS |
|---|---|---|
| sequential control | 272 s | 379 s |
| `--jobs 8` | 159 / 159 / 159 s | 204 / 201 / 209 s |
| `--jobs 12` | 155 / 155 / 157 s | 216 / 238 / 240 s |

**Chosen: `--jobs 8`.** On Ubuntu it lands at 159 s (58% of control, inside the
163 s gate) and 12 buys only 2.5% more. On macOS 8 lands at ~204 s (54% of
control, inside the 227 s gate) while 12 is *slower* — 3 cores oversubscribed
12 ways — and carried three times the failures. A single literal has to serve
both jobs, and 8 is better on the runner that has the least headroom.

A CPU-limited container (`--cpus 4`) agreed on the shape: 171 s sequential,
123 s at 4 jobs, 80 s at 8, 77 s at 12.

### What U0 changed about U1's scope

U0's step 3 offered to narrow U1 to `tests/scripts.bats` alone. That is **not**
what happened: the audit showed `tests/smoke.bats`, `tests/palette.bats` and
`tests/platform.bats` only *read* the deployed `$HOME`, so all four files
parallelize safely and the all-files configuration is both faster and no less
stable. Only `tests/idempotent.bats` is serialized (R3).

## U4 Results (measured 2026-08-21) — the delivered result

CI run `32441162981`, throwaway branch `perf-measure-jobcount`, rebuilt from the
delivery branch. Each job ran its own sequential control plus three `--jobs 8`
repetitions, so every ratio below is same-machine.

**Eight suite runs, zero failures.** R4 is met on both CI jobs.

| Job | Sequential control | `--jobs 8` repetitions | Median | Ratio | 60% gate |
|---|---:|---|---:|---:|---|
| `test-ubuntu` (4 cores) | 288 s | 167 / 166 / 165 s | 166 s | **57.6%** | met |
| `test-macos` (3 cores) | 423 s | 285 / 277 / 283 s | 283 s | **66.9%** | missed |

Ubuntu gains 1.73x, macOS 1.50x. Absolute saving per run: 122 s on Ubuntu, 140 s
on macOS.

**macOS invokes the *stable but slow* stop condition.** Every repetition was
green and the suite lands above 60% of its control, so this does not block; the
residual is filed as
`docs/issues/2026-08-21-012-macos-suite-misses-the-60-percent-wall-time-gate.md`.

These numbers supersede the U0 curve above for judging the ratio. Note the
macOS `--jobs 8` figure moved from ~204 s in U0 to ~283 s here while the control
moved 379 s → 423 s. The post-apply suite is 330 tests in both trees, so the
change is not test growth.

The raised `HERDR_TASK_SYNC_GIT_BUDGET` was the obvious suspect and it does not
account for the gap. A review of every call site settles the size: the budget's
watchdog cancels its timer the moment a healthy probe returns, so the ~50 normal
`hts_location_pass` sites pay nothing for the raise. Only three tests build a
fixture that never returns and therefore always spend the full budget
(`tests/scripts.bats:3276`, `:3354`, `:3410`), at ~1.9 s each — **about 5.8 s in
total**, which cannot explain a 79 s difference.

That leaves macOS runner-to-runner variance, which U0 already recorded at a
340–447 s spread on sequential runs of `main`. **Not proven, just the only
remaining candidate that is large enough.** Issue 012 carries it.

### Container repetitions

`docker run --cpus 4` with `--jobs 8` — a two-times CPU oversubscription, harsher
than either runner. Ten repetitions found one failure, in the repetition that took
161 s against a ~82 s median: `herdr-task-sync orders adapter calls by inbox
commit rather than invocation start`, timing out on a slug that was never
committed.

**After the fix, twelve repetitions of the same profile were clean** — zero
unexpected failures, 81–86 s each. The spread matters as much as the count: the
pre-fix run carried a 161 s outlier against an 82 s median, and that outlier was
the failing repetition. A SIGKILLed engine forces every wait behind it to run to
its ceiling, so removing the kill removed the outlier as well as the failure.

That was a test bug, not a parallelism defect, and it is fixed:
`HERDR_TASK_SYNC_TIMEOUT` defaulted to 5 s in the harness while the engine
`kill -9`s on expiry, and `herdr-task-sync returns before the naming engine
finishes (R8)` ran a stub that sleeps 4 s against it — a one-second margin. The
harness now defaults to the 30 s the engine itself ships in production. Root
cause and evidence are in
`docs/issues/2026-08-20-010-two-herdr-task-sync-tests-flake-under-full-suite-load.md`.

Every container repetition also reports one constant failure,
`Pi brew auto updater focused tests pass`. It fails identically on `main` — the
Docker mount layout does not resolve the test's `../home/...` import — and is
tracked as `docs/issues/2026-08-21-011-pi-brew-test-unresolvable-path-in-docker.md`.
It is not a flake and not caused by this work.

---

## Implementation Units

### U0. Baseline and job-count measurement spike

- **Goal:** the plan's two open numbers — the macOS baseline and the job count — are settled by measurement before any production edit lands.
- **Requirements:** R6, KTD3 groundwork.
- **Dependencies:** none. Runs first.
- **Files:** none (measurement only; use a throwaway branch for the CI runs).
- **Approach:**
  1. **macOS baseline.** Find the most recent CI run whose macOS job passed, and take its post-apply step duration via `gh run view <id> --json jobs`. If no recent green macOS run exists, push an empty commit on a throwaway branch to produce one. Record the figure and set the macOS gate at 60% of it. Do not reuse 416 s from run 32393379268 — that job failed on the post-apply step.
  2. **Job-count curve on Ubuntu.** On the same throwaway branch, run the post-apply suite with `--jobs 4`, `--jobs 8`, and `--jobs 12`, all with `--no-parallelize-across-files` and `BATS_NO_PARALLELIZE_WITHIN_FILE=true` set in every file except `tests/scripts.bats`. Record the three wall times. This also doubles as the scripts-only speedup measurement: it tells you how much of the 107 s reduction the dominant file supplies on its own, before U1 touches anything.
  3. **Decide.** Adopt the best job count as the fixed literal for KTD3. If step 2's scripts-only run already clears ≤ 161 s on Ubuntu, scope U1's audit to `tests/scripts.bats` alone and skip the other four files — they are 14.8% of the baseline combined.
- **Test scenarios:** `Test expectation: none — measurement unit.`
- **Verification:** the macOS baseline, the three Ubuntu wall times, and the chosen job count are written into this plan (Problem Frame and KTD3) before U1 starts.

### U1. Shared-state audit and isolation fixes

- **Goal:** every within-file parallel hazard is found and either fixed (unique paths) or the file is marked for serialization.
- **Requirements:** R3, R4 groundwork.
- **Dependencies:** U0 (its step 3 decides whether this unit covers one file or five).
- **Files:** `tests/scripts.bats` always; `tests/smoke.bats`, `tests/palette.bats`, `tests/platform.bats`, `tests/idempotent.bats`, `tests/helpers/common.bash` only if U0 shows the scripts-only configuration misses the gate.
- **Approach:**
  1. Add `BATS_NO_PARALLELIZE_WITHIN_FILE=true` at file scope in `tests/idempotent.bats` unconditionally (R3). It is 1.3 s of the baseline, so this is free.
  2. Audit `tests/scripts.bats` for fixed shared paths (`/tmp/<literal-name>` without `mktemp` / `$BATS_TEST_TMPDIR`), shared `$HOME` writes, fixed ports or sockets, and lock directories. The Assumptions section already records what a prior pass verified — no `setup_file` / `teardown_file` / `$BATS_SUITE_TMPDIR` usage, no `$HOME` references in this file, the lock at `tests/scripts.bats:1095` already per-test, `CHEZMOI_TEST_CONFIG` uncalled — so treat that as the starting point rather than re-deriving it.
  3. Fix anything found by switching to `$BATS_TEST_TMPDIR` or `mktemp`.
  4. Extend the same audit to the remaining files only under U0's step-3 condition. For any file with structural shared state, add `BATS_NO_PARALLELIZE_WITHIN_FILE=true` at file scope.
- **Test scenarios:** `Test expectation: none — this unit modifies test infrastructure; U4's repeated parallel runs are its proof.`
- **Verification:** sequential suite still passes after the isolation edits — run in Docker via `make test-ubuntu` (or in CI), never on the host: the suite includes `tests/idempotent.bats`, whose real `chezmoi apply` is forbidden on the host by this repo's rules.

### U2. Assert the within-file locking primitive on every runtime

- **Goal:** every runtime that runs the suite with `--jobs` fails loudly and early if `flock` and `shlock` are both missing, instead of failing inside bats mid-suite.
- **Requirements:** R5.
- **Dependencies:** none (parallel-safe with U0 and U1).
- **Files:** `.github/workflows/test-dotfiles.yml` (both test jobs).
- **Approach:** add a one-line assertion — `command -v flock || command -v shlock` — to each test job, before the post-apply step. Nothing is installed: `flock` ships in ubuntu:22.04 and ubuntu-24.04, macOS ships `/usr/bin/shlock`, and the Docker image inherits Ubuntu's `flock`. Per KTD4 this unit installs no GNU parallel, adds no `~/.parallel/will-cite` guard, and does not touch `docker/Dockerfile.ubuntu` or `home/private_dot_config/brewfiles/Brewfile` — which also keeps it clear of the two sibling plans that rewrite those files (Scope Boundaries).
- **Patterns to follow:** existing per-tool steps in the workflow.
- **Test scenarios:** `Test expectation: none — a guard step; proof is U3's parallel runs starting successfully.`
- **Verification:** the assertion step passes in both CI job logs; the CI Ubuntu log shows `bats --version` ≥ 1.5.0 (ubuntu-24.04 ships 1.10.0, which suffices; the check guards against a runner-image pin-back).

### U3. Switch invocations to parallel mode

- **Goal:** every post-apply suite invocation uses `--jobs`.
- **Requirements:** R1, R2.
- **Dependencies:** U0 (supplies the job count), U1, U2. **U0–U4 land in a single PR, and that PR does not merge until U4's repetition and speed gates pass.** U3 rewrites the workflow and the compose services, so merging it on its own single green run would make an unverified configuration the default for every subsequent PR — and any parallelism-only flake would then surface as unrelated red CI on other people's work. U4's own goal already says parallel mode is proven stable "before it becomes the default everywhere"; this dependency is what makes that true.
- **Files:** `.github/workflows/test-dotfiles.yml` (both post-apply steps), `docker/docker-compose.yml` (`test-full` and `test-quick` commands), `Makefile` (new `test-suite` target plus help text), `CLAUDE.md` (the `bats tests/smoke.bats` guidance line, only if wording changes).
- **Approach:** define the invocation once as `bats --jobs <N> --no-parallelize-across-files tests/smoke.bats tests/scripts.bats tests/palette.bats tests/platform.bats tests/idempotent.bats`, with `<N>` the literal U0 chose, and use it in both CI post-apply steps and both compose service commands. Add a `make test-suite` target running the same form so the local path is a working default rather than documentation (R1), list it in `make help`, and update the `CLAUDE.md` test-command line to point at it. Do not use `$(nproc)` for the local count — coreutils is not in the Brewfile, so it would not resolve on a fresh macOS host (KTD3).
- **Test scenarios:** `Test expectation: none — invocation change; U4 owns the behavioral proof.`
- **Verification:** CI run log shows the parallel invocation; `make test-suite` runs the parallel form locally; suite passes.

### U4. Stability and speed verification

- **Goal:** parallel mode is proven stable and measurably faster before it becomes the default everywhere. U3's dependency clause is what enforces the "before".
- **Requirements:** R4, R6.
- **Dependencies:** U3.
- **Files:** none (measurement only).
- **Approach:**
  1. **Stability, under representative load.** Run the parallel suite at least 10 times in a CPU-limited container (`docker compose run --rm --cpus 4 …`), not on the bare 10-core host: at `--jobs 4` on 10 cores the tests get near-dedicated cores, which does not transfer to a 4-core Ubuntu or 3-core macOS runner. Do the apply once and loop only the bats invocation — start `make shell-ubuntu`, perform the source copy, `chezmoi init` and `chezmoi apply` once inside the session, then repeat the suite. Reserve one `make test-ubuntu` run for a final end-to-end confirmation; each of those re-executes the full `brew bundle` apply, so looping it is many times more expensive than the suite it measures.
  2. **Stability, on CI.** Repeat the post-apply step at least 3 times per job via a temporary matrix. macOS especially: it is the environment KTD3 oversubscribes, and a single run cannot separate "no longer flaky" from "did not trigger this time".
  3. **Capture protocol on any failure.** Record what issue `2026-08-20-010` asks for, so a recurrence reopens it with usable evidence rather than reading as a fresh parallelism defect: the bats failure block, whether the engine stub was killed, and the namespace `reconcile.state` and pane `control.state`.
  4. **Speed.** Read the CI post-apply step wall time from `gh run view <id> --json jobs` on both jobs and compare against the baselines (268 s Ubuntu; the macOS figure U0 established). Do not compare Docker wall times against these — per KTD5 the container run is dominated by the apply and has no comparable number.
- **Execution note:** treat **any** failure in **any** repetition as a blocker for that file — serialize the file via KTD2 and re-verify, rather than retrying until green. (The earlier wording, "any failure that repeats in fewer than 5 runs", inverted the intended ordering: read literally it blocked a one-in-five flake while exempting a test that failed every run.)
- **Caveat on what the repetition count proves:** 10 green runs rule out a per-run failure probability around 25% or higher with reasonable confidence; they do not rule out a 5% flake. Record the ceiling the chosen count actually establishes rather than treating green as proof of absence.
- **Test scenarios:** `Test expectation: none — measurement unit.`
- **Verification:** no failures across the container repetitions or the CI repetitions; CI post-apply step wall time ≤ 60% of baseline on both jobs — ≤ 161 s Ubuntu (268 s baseline), and ≤ 60% of the macOS baseline U0 established.

---

## Verification Contract

| Gate | Command | Proves |
|---|---|---|
| macOS baseline is from a green run | `gh run view <id> --json jobs` on the newest passing macOS job | U0; the macOS gate rests on a real number |
| Job count chosen by measurement | Ubuntu wall time at `--jobs` 4, 8, 12 on a throwaway branch | KTD3 |
| Locking primitive present | `command -v flock \|\| command -v shlock` in both CI jobs | R5 |
| Sequential still green after isolation edits | `bats tests/smoke.bats tests/scripts.bats tests/palette.bats tests/platform.bats tests/idempotent.bats` in Docker | U1 didn't break anything |
| Parallel green, repeated | ≥ 10× parallel suite in a `--cpus 4` container, plus ≥ 3× per CI job | R4 |
| Speedup | compare `gh run view <id> --json jobs` post-apply step timings before/after | R6 |
| Lint | `make lint` | script edits clean |

## Definition of Done

- CI (both jobs), both Docker services, and a `make test-suite` target run the post-apply suite with `--jobs <N> --no-parallelize-across-files`, where `<N>` is the literal U0 measured (KTD3).
- Both CI jobs assert `flock` or `shlock` before the post-apply step. No GNU parallel is installed anywhere, and no `~/.parallel/will-cite` guard exists.
- `tests/idempotent.bats` (and any file U1 flags) carries `BATS_NO_PARALLELIZE_WITHIN_FILE=true`.
- No failures across ≥ 10 container repetitions and ≥ 3 repetitions per CI job; CI post-apply step ≤ 60% of baseline on both jobs (161 s Ubuntu; the macOS figure from U0) — **or** the *stable but slow* stop condition was taken, the achieved ratio recorded, and the gap filed in `docs/issues/`.
- U0–U4 landed as one PR that did not merge before U4's gates passed.
- No debugging leftovers (temporary serialization of files the audit cleared, commented-out invocations, the throwaway measurement branch's matrix) in the diff.
