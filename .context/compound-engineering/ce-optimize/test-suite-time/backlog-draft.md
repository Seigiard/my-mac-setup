# Hypothesis backlog draft (pre-CP-2, finalize after baseline)

Costs from probe: full_suite 207s = test_issues 5 + docker_build 4 (warm) + docker_suite 198.
host_suite 222s. Docker suite internals (repo plan data): apply ~100-105s floor, post-apply bats ~159-166s at --jobs 8 (scripts.bats 85%), templates ~5s, smithers tens of seconds.
NOTE: 198s docker_suite < sum of plan-era components → plan numbers are stale; re-derive per-step split before targeting (H0).

H0 (instrumentation, run once, not an experiment): one instrumented docker run with per-step timestamps via a WRAPPER command outside the pinned compose file (docker compose run test-ubuntu with an overridden command? — contract pins compose file content, not an override file) to get the real apply/templates/smithers/post-apply split. Alternative: parse docker_suite.log structure (chezmoi verbose apply lines, bats blocks) + `docker events` timestamps. Cheap and safe: grep log line offsets? No timestamps in log. Use `ts`-like wrapper: pipe compose output through awk adding elapsed — changes nothing inside container. DO THIS FIRST at next measurement.

H1 [docker, high impact, medium risk] Named cache volumes for the test-ubuntu/test-full services: ~/.cache/chezmoi (3 GitHub tarballs/run), ~/.bun/install/cache (2× bun install), mise download cache, OMZ/plugin git clones (via cache dir? clones go to ~/.oh-my-zsh — that's state, not cache; only cacheable via H2 bake instead). Persist caches across runs; first run seeds. Risks: staleness masking upstream decay (accepted locally; CI/nightly still cold), determinism (cache is content-addressed for bun; chezmoi refreshPeriod=168h governs externals). Contract: tests/test_docker_contract.py — check what it pins about compose volumes.
Expected: kill most of per-run network fetches. Est 20-60s of docker_suite.

H2 [docker, medium impact, medium risk] Bake apply residual into image: pre-run OMZ install + 4 zsh plugin clones + mise node@lts + fff-mcp during image build (same pattern as baked Brewfile, deferred follow-up named in docs/plans/2026-08-20-2217-perf-docker-baked-brewfile-plan.md:16). Scripts are run_onchange → they still run; must verify their guards make them near-noop when target state exists. Est 8-9s residual + OMZ/mise/fff fetch time (overlaps H1).

H3 [both, medium impact, needs per-site care] Fixed negative-assertion sleeps in scripts.bats (:5405,:5550,:5569 sleep 6,:5609,:5944,:3269) + palette.bats:1050 sleep 5, :212 sleep 1 ≈ 19-20s serialized. Replace with event-based completion waits where a positive completion event exists (e.g., process exit) keeping the same detection window semantics, or shrink oversize windows (sleep 6 vs HTS_TIMEOUT=1). MUST NOT weaken detection: analyze each site; keep window ≥ the timeout it polices + margin. Est 10-15s per platform.

H4 [both, small-medium, low risk] hts wait latency: poll interval 0.25s → 0.02-0.05s in hts_wait_for_call/hts_wait_for_state (helpers/herdr_task_sync.bash:1055-1063,1083-1090, HTS_WAIT_SLOW_POLLS :737), keep 60s ceiling; replace $(seq 1 6000) with counter while-loop (subprocess + 6000-word list per wait × ~94 sites). Keep the 0.02s settle sleeps (race guards). Est 3-10s per platform.

H5 [both, big effort, structural] Split scripts.bats into topic files + drop --no-parallelize-across-files with idempotent.bats moved to its own serial bats invocation (preserves its shared-$HOME safety). Unlocks cross-file parallelism; removes the 85% single-file floor. Requires test_post_apply_suite_contract.py update + new regression tests + re-check elapsed-seconds assertions under new contention. Est 15-40s but high validation cost. Only if plateau not reached via cheaper wins.

H6 [host, high impact, low-medium risk] Local macOS bats semaphore: host has only shlock (1s poll under contention); no flock, no lockf. Provide a local flock-compatible shim (python3 fcntl.flock based) on PATH for local Darwin runs only, wired inside run-post-apply.sh (argv contract untouched; CI wrapper untouched). CI macOS evidence: wrapper cut suite 66.9%→58.8% of sequential. Est 20-40s host. New regression test for shim semantics.

H7 [host+docker, tiny, trivial] Makefile: run test-issues and build-docker concurrently for test-ubuntu (both are prerequisites, independent; canonical target preserved). Est 4-5s full_suite. Check test_docker_contract pins.

H8 [docker, small] Deduplicate bun install: same-container second install (make test-smithers) should already hit warm ~/.bun cache; with H1 volume both go warm across runs. Possibly symlink/share node_modules keeping pinned paths (test_docker_contract.py:46, scripts.bats:6242). Fold into H1 measurement; separate only if residual visible.

H9 [docker+CI, small] templates.bats: 35 chezmoi execute-template spawns → batch? Risky for assertion structure; low value (~5s file total). Defer.
H10 [both, small] palette.bats 45 python3 boots; hoist safely? Defer.
H11 [both, small] smoke.bats 2 bun test boots → single invocation changes granularity. Defer.
H12 [host, small] test-issues python subprocess spawns + 0.45s lock sleeps. 5s ceiling. Defer.

Order: H0 (instrument) → H6, H1 (biggest per-platform) → H4, H7 → H3 → H2 → reassess → H5 only if still short.
All dep_status: approved (no new external dependencies; H6 shim uses system python3).
