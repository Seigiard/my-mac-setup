# test-suite-time optimization — coordination state

Updated: 2026-08-28 (Phase 0/1)

## Run identity
- Branch: `optimize/test-suite-time` in worktree `.claude/worktrees/optimize-test-suite-time`
- Starting commit: `01a73d5eec551fd0143753bd366791d07bc94d52`
- Spec: `.context/compound-engineering/ce-optimize/test-suite-time/spec.yaml` (CP-0 done)
- Experiment log: `.context/compound-engineering/ce-optimize/test-suite-time/experiment-log.yaml` (pending CP-1)
- Autonomy: invoking arguments pre-authorize skipping interactive gates; recorded here.

## Environment
- macOS 14.7.4, Darwin 23.6.0, 10 CPU, 32 GB RAM
- Docker 29.4.0, Bats 1.14.0, chezmoi v2.72.0, Python 3.14.7, bun 1.4.0

## Production commands (the measured suite)
1. `make test-issues`
2. `make build-docker`
3. `docker compose -f docker/docker-compose.yml run --rm -T test-ubuntu` (full suite incl. apply + idempotent.bats)
4. `make test-suite` (host-safe macOS suite)
Harness: `measure-suite.sh` (immutable), JSON output, stdin </dev/null.

## Prior learnings (from docs/solutions, consolidated)
- Verify with skip-SET parity (lines with reasons), not counts.
- Benchmark non-TTY; interactive stdin changes suite behavior (2026-08-24 hang issue).
- Do not touch: idempotent.bats disposable-home guard, nested one-test bats probe, 30s watchdog static test, CI timeout ceilings.
- scripts.bats elapsed-seconds assertions calibrated at --jobs 8.
- Prior perf work: CI-minimal brew render (~178s→s), one-test probe file.

## Subagents
- learnings-researcher: DONE (findings above)
- docker-pipeline explorer: running
- bats-suite explorer: running

## Docker pipeline profile (explorer report, consolidated)
Container steps (docker/docker-compose.yml:114-134): stage copies → chezmoi init → bats templates.bats (~5s) → chezmoi apply (dominant; was 223-235s pre-bake, floor ~100-105s post-bake) → make test-smithers (bun install+tsc+bun test) → run-post-apply.sh full (268s sequential / 159s at --jobs 8; scripts.bats = 228s = 85%).
Key facts:
- Image bakes: apt, Linuxbrew, chezmoi, bats, fzf, bun, full Brewfile (Dockerfile.ubuntu:97-101). Only COPY = Brewfile.tmpl; editing anything else keeps build cached (~1s).
- Cold on EVERY run (container HOME discarded, no volumes/cache mounts): 3 chezmoi external tarballs (linear-cli, slopfiles, claude-skills), OMZ install + 4 zsh plugin git clones, mise node@lts download, fff-mcp curl|bash, 2× bun install (script _4 → ~/.claude/.smithers AND make test-smithers → worktree), brew bundle verify walk.
- chezmoi apply runs 3× per container (compose + idempotent.bats twice).
- Fixed sleeps ~18s wall: scripts.bats sleep 6 (:5569), sleep 2 ×5 (:3269,5405,5550,5609,5944), palette.bats sleep 5 (:1050), sleep 1 (:212). bats dispatcher polls free slots with sleep 1.
- Host: test-issues (~90 python subprocesses, 3×0.15s lock sleeps) serial before build-docker (Makefile:32) though independent.
- Contract pins: tests/test_docker_contract.py:23-30 pins `run --rm test-ubuntu` cmdline + :46 pins literal `make test-smithers`; scripts.bats:6242 needs $SOURCE_ROOT/.../dot_smithers/node_modules/.bin/smithers.

Top leads (explorer ranking):
1. Cache mounts/named volumes for ~/.cache/chezmoi, bun cache, OMZ+plugins.
2. Bake apply residual (OMZ, plugins, mise node, fff-mcp) into image (pattern proven by Brewfile bake; deferred follow-up in docs/plans/2026-08-20-2217-perf-docker-baked-brewfile-plan.md:16).
3. scripts.bats = 85% of suite: split for cross-file parallelism (deferred in perf-parallel-bats-suite-plan.md:88); replace fixed negative-assertion sleeps with bounded polls.
4. Collapse duplicate bun install (symlink/share node_modules; keep pinned paths).
5. Unserialize host test-issues vs build-docker.

## Bats suite profile (explorer report, consolidated)
- scripts.bats = 254 tests, ~85% of post-apply suite (~228s of 268s sequential; --jobs 8 → 166s Ubuntu). Others <25s each. idempotent.bats = 1.3s (applies are near-noop after compose's apply; NOT dominant).
- Fixed unconditional sleeps ~14s serialized in scripts.bats: :5405,:5550,:5569(sleep 6),:5609,:5944,:3269 — all negative assertions ("log stayed empty"). palette.bats:1050 sleep 5, :212 sleep 1.
- Polling: hts_wait_for_call/state poll at 0.25s (helpers/herdr_task_sync.bash:1055-1063,1083-1090; HTS_WAIT_SLOW_POLLS :737); unconditional sleep 0.02 settles at :1192,1209; each wait runs $(seq 1 6000).
- common.bash per-file load: chezmoi source-path spawn paid ~8× per file under parallel workers (:35). chezmoi_test_init dead code (0 callers).
- templates.bats: 35 chezmoi execute-template spawns; palette.bats: 45 python3 spawns + per-test mktemp; smoke.bats: 2 separate bun test boots (:909,:919).
- Serialization: --no-parallelize-across-files exists solely for idempotent.bats shared-$HOME apply; scripts.bats within-file parallel-safe via HTS_WORK mktemp isolation. Only idempotent.bats sets BATS_NO_PARALLELIZE_WITHIN_FILE.
- Contract pins: test_post_apply_suite_contract.py:37-63 pins exact bats argv both modes (order incl.); :21-35 pins occurrence counts of runner invocations in workflow/compose/Makefile. test_macos_bats_flock_wrapper.py pins flock→lockf shim semantics.
- Bats explorer top leads: (1) remove/shrink fixed sleeps; (2) 0.25s→0.02s poll interval + drop settle sleeps; (3) split scripts.bats into topic files (structurally correct fix, named in issues 2026-08-21-006/012; contract update needed); (4) drop --no-parallelize-across-files after isolating idempotent.bats (contract update needed); (5) amortize process spawns (palette python3, templates chezmoi, smoke bun).

## Baseline
- pending (probe run first, then 3 timed repetitions)

## Hypotheses / experiments
- pending Phase 2

## Retained changes
- none yet

## Remaining work
- Probe + baseline, profile consolidation, hypothesis backlog, experiment loop, final verification (macOS + Ubuntu), report in docs/benchmarks/test-suite-optimization.md
