# bashunit-full-suite experiment — status

Re-read this file before every batch. Update after every batch.

## Baseline environment (recorded 2026-08-28)

- Worktree: `.claude/worktrees/optimize-test-suite-time` (branch `optimize/test-suite-time`)
- Starting commit: `01a73d5` (same as main)
- macOS 14.7.4 arm64; system bash 3.2.57; zsh 5.9.2
- Bats 1.14.0 (installed)
- bashunit: NOT installed; brew stable is 0.50.1 → pin 0.50.1 for the experiment
- Production runner: `tests/run-post-apply.sh` → `bats --jobs 8 --no-parallelize-across-files`
  - full: smoke, scripts, palette, platform, idempotent
  - host-safe: same minus idempotent
- Scenario counts (`grep -c '^@test'`): smoke 74, scripts 254, palette 57, platform 2, idempotent 13 → **400 total**
- Line counts: smoke 1035, scripts 6437, palette 1068, platform 34, idempotent 180, helpers/common.bash 206
- full suite (idempotent.bats) requires disposable HOME → only in Docker (`make test-ubuntu`); host runs host-safe only
- Host constraint: never `chezmoi apply` / bare `chezmoi init` on host

## Phase status

- [x] 1. Baseline recording (env/versions above; timings pending)
- [ ] 2. Inventory Bats-specific behavior (subagents) → `.context/bashunit-full-suite/inventory-*.md`
- [ ] 3. bashunit implementation + 1:1 scenario mapping
- [ ] 4. Side-by-side per-scenario verifier
- [ ] 5. Negative controls
- [ ] 6. Parallelism (8 workers where safe)
- [ ] 7. macOS + Ubuntu(Docker) verification
- [ ] 8. Paired timing runs (3+ interleaved reps, host-safe + full)
- [ ] 9. Review subagents (parity, cleanup, coverage)
- [ ] 10. Verdict + docs/benchmarks/bashunit-full-suite-experiment.md

## bashunit probe results (verified on host)

- Installed pinned 0.50.1 at `tests/lib/bashunit` via `curl install.sh | bash -s tests/lib 0.50.1` (checksum-verified single file). Runs fine under macOS bash 3.2.
- Parallel: `-j N` / `--parallel`; reports: `--report-junit/--report-tap/--report-json`; filter `-f`; `--list`; `--show-skipped`.
- Skip API is namespaced: `bashunit::skip "reason"` (bare `skip` = command not found). Also `bashunit::skip_if/skip_unless/skip_unless_command/skip_on`.
- Test files must match `*test.sh`; tests are `function test_*`.

## Decisions

- Use existing locked worktree `optimize/test-suite-time` as the dedicated worktree.
- Pin bashunit 0.50.1 (matches brew stable), install as repo-local artifact so Docker gets the same version.

## Failures / risks

(none yet)

## Baseline timings

- Rough (CONTENDED — 3 subagents running; NOT valid performance evidence): `tests/run-post-apply.sh host-safe` wall 4:09.53 (164% cpu), exit 1 — 386 ok, 1 fail: test 195 "herdr-task-sync fails open for missing tools contention write failure and malformed input", a load-sensitive deadline check (elapsed 5712ms > allowed 5585ms). Failure consistent with contention; formal paired timings must run quiet, and only clean runs count.

## Inventory results (phase 2)

- inventory-scripts.md: 254 tests confirmed. Hazards: (1) self-recursive `bats` runs asserting runner-of-Bats properties (line 2747 runs `bats "$BATS_TEST_FILENAME" --filter`, lines 2419/2439 nested bats on probe file); (2) mid-test `teardown; setup` re-invocation at 10+ sites; (3) merged-stream `$output`, `$lines` last-line asserts, exact exit codes 1/2/97/124; (4) daemons/pid files/signal traps, teardown kill-and-poll must run after failures; (5) `/tmp/htspwn$BATS_TEST_NUMBER` uniqueness, 116 conditional skips (jq ×96), common.bash `load`s bats-libs.
- inventory-smoke-palette.md: smoke 74, palette 57 confirmed. Hazards: `run` on shell functions/heredocs; PATH/cwd mutation relies on Bats per-test subprocess isolation; bats-assert/file vocabulary (`assert_line --index`, `refute_line --regexp`, `$lines` drops empty lines); `fail` returns 1 semantics; timing-sensitive palette tests 11 & 57 + ~15 real-fzf ranking tests; smoke 64/66 spawn full Bun suites.
- inventory-platform-idempotent.md + bashunit-capabilities.md: pending (agent running).

## Completed batches

- Phase 1 baseline env + pinned bashunit install (uncommitted yet).
- Phase 2 inventories: scripts, smoke+palette done; platform/idempotent + capabilities pending.
