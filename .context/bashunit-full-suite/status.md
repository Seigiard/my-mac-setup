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
- [x] 2. Inventory Bats-specific behavior (subagents) → `.context/bashunit-full-suite/inventory-*.md`
- [x] 3. bashunit implementation + 1:1 scenario mapping (400/400)
- [x] 4. Side-by-side per-scenario verifier
- [x] 5. Negative controls (all 6 + positive control pass)
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

### Peer-session coordination (2026-08-28)
- Another session (ce-optimize timing) shared this worktree, switched branches under us; now relocated to `.claude/worktrees/optimize-test-suite-timing`. This worktree stays on `optimize/test-suite-time`. Rule agreed: mutual pings before CPU-heavy/measurement windows; no docker overlap. HOLD all test execution until peer pings "window closed".
- My commit 5a20263 accidentally swept peer's `.context` files (harmless). Only stage `.context/bashunit-full-suite/` from now on.

### scripts.bats: 3 failing scenarios after first comparison (251/254 parity)
1. "herdr-task-sync writer and reader agree on the record name for an awkward session id" — missing generic `assert` in shim → FIXED (added `assert`), not yet re-verified.
2+3. "herdr-child superseded watcher cannot publish failure metadata over a new generation" and "herdr-child sliced wait revalidates generation before liveness refresh" — deterministic fails under shim, pass under bats. Deep diagnosis so far:
   - Reproduces under plain bash driver (no bashunit) → environment semantics, not bashunit runtime.
   - NOT caused by: run-in-subshell (bats also subshells), shell opts (bats has -eET+functrace; enabling them doesn't fix), SHELLOPTS export (not exported by bats), rm/glob.
   - BASH_ENV+xtrace of ALL child bash procs shows IDENTICAL process behavior in bats vs shim: watcher dies at `return 20` (errexit at watcher_generation_current return, herdr-child's own set -e), run dir runs/<armed-gen> NEVER removed in either env (PATH rm/rmdir spy over a PASSING bats run proves no deletion).
   - Therefore in bats `old_generation=$(cat $CHILD_STUB/generation)` must read a value ≠ armed-gen (assert_file_not_exists passes on a never-created path). In shim it reads armed-gen (= watcher run dir → exists → fail).
   - In shim run, calls.log shows exactly 2 report-metadata calls, generation file = armed-gen at read time. Open question: what does bats read there?
   - NEXT DECISIVE STEP (when peer window closes): BASH_ENV trace gated on BATS env (trace bats-exec-test itself) to capture the expanded `cat generation` value and report-metadata ordering under bats.
   - Changed run() from $(…) capture to subshell+tempfile capture (bats-like fd semantics; prevents SIGPIPE of detached continuations) — kept regardless; not yet re-verified against full scripts file.

### Baseline contended failure
- test 195 (fail-open deadline) failed in the contended rough baseline; load-sensitive.

## Baseline timings

- Rough (CONTENDED — 3 subagents running; NOT valid performance evidence): `tests/run-post-apply.sh host-safe` wall 4:09.53 (164% cpu), exit 1 — 386 ok, 1 fail: test 195 "herdr-task-sync fails open for missing tools contention write failure and malformed input", a load-sensitive deadline check (elapsed 5712ms > allowed 5585ms). Failure consistent with contention; formal paired timings must run quiet, and only clean runs count.

## Inventory results (phase 2)

- inventory-scripts.md: 254 tests confirmed. Hazards: (1) self-recursive `bats` runs asserting runner-of-Bats properties (line 2747 runs `bats "$BATS_TEST_FILENAME" --filter`, lines 2419/2439 nested bats on probe file); (2) mid-test `teardown; setup` re-invocation at 10+ sites; (3) merged-stream `$output`, `$lines` last-line asserts, exact exit codes 1/2/97/124; (4) daemons/pid files/signal traps, teardown kill-and-poll must run after failures; (5) `/tmp/htspwn$BATS_TEST_NUMBER` uniqueness, 116 conditional skips (jq ×96), common.bash `load`s bats-libs.
- inventory-smoke-palette.md: smoke 74, palette 57 confirmed. Hazards: `run` on shell functions/heredocs; PATH/cwd mutation relies on Bats per-test subprocess isolation; bats-assert/file vocabulary (`assert_line --index`, `refute_line --regexp`, `$lines` drops empty lines); `fail` returns 1 semantics; timing-sensitive palette tests 11 & 57 + ~15 real-fzf ranking tests; smoke 64/66 spawn full Bun suites.
- inventory-platform-idempotent.md + bashunit-capabilities.md: pending (agent running).

## Completed batches

- Phase 1 baseline env + pinned bashunit install (uncommitted yet).
- Phase 2 inventories: scripts, smoke+palette done; platform/idempotent + capabilities pending.


## MILESTONE 2026-08-28 (after peer window 2 closed)

- HOST PARITY COMPLETE: platform 2/2, palette 57/57, smoke 74/74, scripts 254/254, idempotent 13/13 (guard/skip mode) — 400/400 scenarios, skip reasons included.
- Root cause of herdr-child mismatches: bats-file assert_file_not_exists tests -f; run DIRECTORY survives vacuously in bats. Shim now mirrors -f. Issue filed: docs/issues/2026-08-28-001-*.md.
- ALL NEGATIVE CONTROLS PASS (incl. leak). Two harness bugs found by controls: macOS pgrep has no -E (leak check was inert); snapshot matched its own pipeline.
- Machine debris: 12 orphaned herdr-child watchers + 2 stub prompts killed (leaked by bats runs both sessions). Explains peer's ambient drift; both suites re-leak watchers whose launchers die — NOT flagged by per-file leak_check when teardown kills them; the orphans came from ABORTED runs.
- Stale stub dirs (680) moved to ~/.scratchpad/stale-child-stubs-1787898087 (tell user: rm -rf ~/.scratchpad/* to purge).

## REMAINING

1. Clean 5-file comparison pass with WORKING leak checks (~7 min) — announce to peer.
2. make test-ubuntu with bashunit comparison inside Docker (full mode incl. real apply idempotent scenarios) — command sketch:
   `docker compose -f docker/docker-compose.yml run --rm test-ubuntu '<stage worktree>; ...; tests/bashunit/compare-suite-file.sh <each file>'` — simplest: run normal entrypoint but append compare runs; needs bats + bashunit both present in image (bashunit rides in tests/lib).
3. Exclusive benchmark window (announce): tests/bashunit/bench-bats-vs-bashunit.sh host-safe 3+ on macOS; full mode inside docker.
4. Review subagents (parity/cleanup/coverage), fix findings, rerun.
5. Verdict + fill docs/benchmarks/bashunit-full-suite-experiment.md.


## Ubuntu/Docker results (2026-08-28, container quiet)

- FULL-MODE PARITY: 400/400 all five files incl. real chezmoi-apply idempotent scenarios.
- FULL-suite paired bench (3 reps, in-container, pre-errtrace shim): bats median 77065ms (CV 1.6%) vs bashunit 60449ms (CV 0.2%) → **-21.6%, beyond noise**, all exits 0.
- scripts x2 rerun: run1 LEAK-BOTH identical watcher class (symmetric, pre-existing). run2: (a) bats-only sweep-daemon leak → gate must be directional (fail only on bashunit-only leaks) — FIX PENDING; (b) FLAKE: "herdr-child reap invalidates before close while spontaneous loss wakes the parent" failed under bashunit run2 only (passed run1 + all host runs) — needs flake-rate measurement under BOTH runners in docker before parity claim is final.

## Parity review resolution (review-parity.md)

- HIGH-1 helper-depth failures: FIXED via set -E + bashunit-frame-filtered ERR handler; probe matrix re-verified (bare body fail, helper partial fail, fail-call all red on both runners).
- HIGH-2 bash-5 trap semantics: to be confirmed by final docker pass with NEW shim (staged copies in earlier docker runs used the pre-errtrace shim).
- MEDIUM run() late-write divergence: documented deviation (bats would hang on stdout-holding daemon; shim returns at child exit).
- MEDIUM zero-arg assert_output inversion: zero call sites in suite; documented, not churned.
- MEDIUM setup_file ':' masking: fixed in converter. MEDIUM leak paths: TMPDIR globs added.
- Coverage review: manifest exact both directions; function names now file-prefixed (collision fixed); 3 scenarios keep runtime bats dependency (scripts #101-103; #103 also requires tests/scripts.bats to remain) — verdict-relevant; orphaned probe file tests/herdr_child_descriptor_probe.bats = pre-existing dead coverage (issue to file).
