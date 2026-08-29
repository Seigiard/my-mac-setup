# Test-suite optimization — 2026-08-29

Full production test suite wall-clock time reduced **from 159s to 128s median (−31s, −19.5%)** with zero change to test outcomes: identical test counts, identical skip sets with reasons, zero failures, on both macOS (host) and Ubuntu (docker) legs.

Raw data: [`test-suite-optimization-measurements.json`](test-suite-optimization-measurements.json).

## Scope and commands

The production suite measured is the sum of:

```sh
make test-issues
make build-docker
docker compose -f docker/docker-compose.yml run --rm -T test-ubuntu
make test-suite
```

The docker leg applies the checkout inside Ubuntu 24.04 (chezmoi init → templates → apply → `make test-smithers` → post-apply bats). The host leg (`make test-suite`) runs the parallel host-safe bats files against the applied `~/` on macOS.

- Baseline: `origin/main` at 9161046.
- Final: `optimize/test-suite-timing` at a1e1ca3 (baseline + 4 commits).

## Result

3 clean interleaved baseline/final pairs (docker 431 tests / 11 skips, host 390 tests / 2 skips, 0 failures in every kept rep), 12/12 line-diff skip-and-fail parity checks exact:

| Metric | Baseline (raw → median) | Final (raw → median) | Δ |
|---|---|---|---|
| Full suite wall | 163, 158, 159 → **159s** | 131, 127, 128 → **128s** | **−31s (−19.5%)** |
| — docker leg | 158, 153, 153 → 153s | 126, 122, 123 → 123s | −30s (−19.6%) |
| Host suite wall | 138, 139, 138 → 138s | 136, 141, 138 → 138s | 0s (unchanged) |

Paired per-rep full-suite deltas: −32, −31, −31. MAD ≤ 2s on every metric — far past the 5% relative noise threshold (~8s) the run used for keep decisions. The host suite is untouched by the kept changes (all affect only the docker leg and one bun test file). One additional pair was discarded whole (never patched one-sided) when a pre-existing load-sensitive race test failed on one side — see docs/issues/2026-08-29-004; its raw numbers agreed with the kept pairs.

## Retained changes (4 commits)

1. **`HOMEBREW_BUNDLE_NO_UPGRADE=1` in the compose test services** (a873ac1). The container's job is to prove every Brewfile dependency is present and the apply succeeds — not to chase upstream version drift. Without it, a stale image spent ~30s per run fetching metadata and upgrading formulae. Container-only; host and production apply semantics untouched.
2. **Injectable CLI timeout in `publishIssue`** (92dbbda). The two issue-writer timeout tests each burned a full 5s production timeout waiting for a stubbed CLI. `publishIssue` now takes `timeoutMs = ISSUE_CLI_TIMEOUT_MS`; the sole production caller keeps the default.
3. **Baked bun install cache in `docker/Dockerfile.ubuntu`** (7c08c19). A layer keyed on `package.json` + `bun.lock` warms bun's global cache at image-build time, so both runtime `bun install --frozen-lockfile` runs (the chezmoi run_onchange script and `make test-smithers`) resolve from cache instead of the network. The runtime installs still run frozen against the real tree, so the lockfile-vs-tree invariant (docs/issues/2026-08-19-001) is untouched; only the network cost moves to a cached image layer.
4. **Review-driven coverage hardening** (a1e1ca3). The final coverage review found that after (2), no test proved the production default timeout still fires against a hung CLI. One of the two timeout tests was restored to the no-arg default (spending ~5s by design; the other keeps a 300ms injection), and `HOMEBREW_BUNDLE_NO_UPGRADE=1` was pinned into `tests/test_docker_contract.py`'s literal per-service contract (control-checked red against origin/main) so a silent revert of (1) cannot pass unnoticed. The headline above was re-measured after this commit.

## Rejected experiments

- **macOS flock-compatible semaphore shim** for local host runs: consistently faster but below the noise threshold; reverted, design preserved in docs/issues/2026-08-28-002.
- **hts wait-poll latency 0.25s→0.05s + seq-subprocess elimination**: measured dead neutral (full −1s, host +2s) — wait completion is event-dominated, not poll-quantization dominated. Reverted. As a side product, every fixed sleep in scripts.bats was audited and proven to guard a real margin (stub delays, kill-race margins); none is safely shrinkable.
- **Not attempted** (time budget / below noise / overlap): Makefile target overlap (est. 4–5s, sub-noise), container cache volumes (superseded by the bake layer), scripts.bats file split for cross-file parallelism (structural, the largest remaining lever), spawn amortization (micro).

## Verification evidence

- **Correctness review** (independent subagent): all changed files verified behavior-preserving against origin/main, assertion-by-assertion for the test file; production `publishIssue` caller keeps the 5s default; frozen-lockfile checks proven unmaskable by a warm cache; issue-writer tests re-run green (35/35).
- **Coverage review** (independent subagent): no test deleted, renamed, merged, or skipped anywhere in the diff; two findings (default-timeout proof, contract pin) — both fixed in a1e1ca3; explicitly recommended no Dockerfile text assertion (would be tautological; the layer self-detects at build time).
- **Skip parity**: every kept rep's SKIP/FAIL lines (with reasons) line-diffed against the anchored outcome sets — 12/12 exact. Counts moved from the run's original baseline (428/387) only via upstream main adding 3 tests and this worktree's smithers deps making one former host skip execute (and pass).
- **Process cleanup review**: no orphaned watcher daemons, no leaked containers/volumes from the run, no stray bats processes. One finding: `hts.*` temp-dir accumulation under `$TMPDIR` (pre-existing teardown race), filed as docs/issues/2026-08-29-003.
- **Methodology review**: interleaving, exclusions, noise floor, baseline validity, warm-cache fairness, and every statistic recomputed and confirmed sound; its two caveats are folded into this document.
- **Platforms**: Ubuntu leg exercised in every docker rep (431 tests); macOS host leg in every host rep (390 tests). CI runs both jobs on every push.

## Caveats and trade-offs

- **Measurement environment**: a live user machine with a concurrent agent session and a runaway process pinning one core. All keep decisions used adjacent interleaved A/B pairs under a negotiated exclusive-window protocol with orphaned-watcher reaping between reps; absolute times are not comparable across windows, deltas are.
- **Image staleness trade-off**: with `HOMEBREW_BUNDLE_NO_UPGRADE=1`, containers no longer pick up formula upgrades at run time; upstream drift now surfaces only when the image is rebuilt. That is the intended hermetic behavior for a test container.
- **Lockfile-change cost**: the bake layer rebuilds whenever `package.json`/`bun.lock` change — one network-heavy image build, then cached again. That recurring cold-build cost was not measured in this run.
- **Measurement order**: each interleaved pair ran baseline-then-final (no ABBA counterbalancing). The machine's documented ambient drift direction (slowing over a session) biases against the final side, so the result is, if anything, conservative.
- **Flaky neighbor**: a pre-existing race test (`herdr-child reap invalidates before close…`, from #83) fails under CPU contention (3 of ~16 loaded container runs vs 0 of 10 calm; runner-independent). Filed as docs/issues/2026-08-29-004. Contaminated pairs were discarded whole and replaced.
- **Runner interaction**: a parallel unpushed branch (`optimize/test-suite-time`) replaces the post-apply bats runner with bashunit. All retained commits here are runner-independent and carry over that migration unchanged, but the two branches' percentage gains were measured against different runners and do not add linearly. Expect a trivial textual merge conflict in `docker/docker-compose.yml` (both branches touch service definitions) and one issue-number collision to renumber (both branches filed a 2026-08-28-001).

## Remaining bottlenecks and recommendation

Post-apply bats inside the container is now the long pole (~100s, of which `tests/scripts.bats` is ~80s and runs with `--no-parallelize-across-files`). Splitting scripts.bats into parallelizable files is the largest remaining lever but structural — and moot if the bashunit runner branch lands first. Recommendation: merge these four commits as-is; re-profile after the runner branches reconcile before investing in the split.
