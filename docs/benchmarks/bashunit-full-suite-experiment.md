# bashunit full-suite migration experiment

Status: COMPLETE.

## Question

Can the full production post-apply shell-test suite (`tests/run-post-apply.sh`:
smoke, scripts, palette, platform, idempotent — 403 scenarios after the rebase
onto main `9161046`) migrate from
Bats 1.14 to bashunit 0.50.1 with behavior preserved and wall-clock time
reduced? The Bats files are the immutable behavioral oracle.

## Verdict

**`bashunit-full-suite-win`**

- Behavior preserved: per-scenario parity 403/403 (status, skip reasons,
  exit codes) on macOS (host-safe, 390) and Ubuntu/Docker (full mode incl.
  real `chezmoi apply` idempotent scenarios, 403), verified by a
  manifest-keyed per-scenario verifier whose failure detection is proven by
  8 negative controls. Flake re-check: 0/10 failures on both runners for the
  one scenario that flaked once.
- Wall-clock reduced beyond noise: −24.1% host-safe on macOS, −24.4% full
  mode in Docker (3 interleaved paired reps each, worst CV 2.1%, only
  clean-exit repetitions counted).
- Cleanup parity holds within the monitored leak classes (see Cleanup
  evidence for the scope qualification).

Caveats carried into production: bats stays installed for three
nested-runner scenarios; the compat shim is a real maintenance surface
(see Maintenance cost); the watcher-class leak allowlist is rate-blind by
design, with counts reported per run.

## Environment

- macOS 14.7.4 arm64, system bash 3.2.57, Bats 1.14.0 (host)
- Ubuntu via `make test-ubuntu` Docker workflow (full mode incl. idempotent)
- bashunit 0.50.1 pinned as a checksum-verified single file at
  `tests/lib/bashunit` (installed via
  `curl -fsSL https://bashunit.typeddevs.com/install.sh | bash -s tests/lib 0.50.1`,
  SHA256 `18d83d…17d93`)
- Starting commit `01a73d5`; experiment branch `optimize/test-suite-time`

## Approach

- `scripts/bats2bashunit.py` — deterministic converter; transforms only the
  `@test "…" {` lines (bodies stay byte-identical), emits a per-scenario
  manifest (`tests/bashunit/manifest.tsv`) proving a one-to-one mapping.
- `tests/bashunit/bats-compat.bash` — compatibility shim reproducing measured
  Bats semantics: ERR-trap + final-status failure detection (reproduces the
  bash-version-dependent inert mid-test `[[ ]]` quirk by running under the
  same interpreter), `run` via subshell + tempfile capture, `$status/$output/
  $lines`, the bats-assert/bats-file vocabulary subset in use, `skip` from any
  call depth, setup/teardown adaptation with teardown-after-failure.
- `tests/bashunit/compare-suite-file.sh` — side-by-side runner: production-
  shaped Bats run vs `bashunit -j 8` per file, plus process/path leak checks.
- `tests/bashunit/verify_bats_bashunit.py` — per-scenario verifier keyed by
  the manifest: presence, status parity, skip-reason parity. Aggregate counts
  are never used as evidence.
- `scripts/run-negative-controls.sh` — proves the verifier rejects: missing
  scenario, duplicated mapping, incorrect skip, weakened assertion
  (fail→pass), skip-reason drift, leaked process/path; plus a positive
  control and an allowlist-blindness control that documents the one accepted
  hole (a bashunit-only leak of the oracle-stochastic watcher class is
  excused by design and visible only via LEAK-INFO counts). 8 controls total,
  all passing.

## Scenario coverage

| file | scenarios | macOS parity | Ubuntu parity (full mode) |
|---|---|---|---|
| platform.bats | 2 | OK | OK |
| palette.bats | 57 | OK | OK |
| smoke.bats | 74 | OK | OK |
| scripts.bats | 257 | OK | OK (flake-rate 0/10 both runners for the one once-flaky scenario) |
| idempotent.bats | 13 | OK (guard/skip mode) | OK (real chezmoi apply) |

Independent coverage review reconciled the manifest exactly in both
directions (verbatim skip messages, no duplicates) at 400 scenarios; the
rebase added three scripts scenarios (`run --separate-stderr` +
`assert_stderr`/`refute_stderr`, support added to the shim) for 403 total,
re-verified per-scenario on both platforms.

## Compatibility findings

- bashunit runs each test in a subshell; skip/assert state does not survive
  nested subshells — the shim must run bodies directly in the test subshell.
- Bare command failures do not fail bashunit tests (Bats fails them via its
  ERR trap); assertion failures do not stop the body (Bats aborts). The shim
  restores both behaviors.
- `skip` from `set_up` is broken in bashunit 0.50.1 (spurious hook-failure
  test); the shim inlines `setup` into the body instead.
- No cross-file exclusivity control in bashunit (`--no-parallelize-across-
  files` equivalent); mirrored by invoking bashunit once per file.
- bashunit "risky" (zero recorded assertions, exit 0) maps to Bats "pass" —
  tests whose checks are bare commands + `fail()` are ordinary passes in Bats.
- Bats `run` captures to files, not pipes: a `$(…)`-based shim SIGPIPEs
  detached daemons that outlive the test command. The shim captures via
  subshell + tempfile with zero external commands (tests legitimately empty
  PATH before `run`).
- bats-file's `assert_file_not_exists` tests `-f` (regular file): asserting
  absence of a path that is a DIRECTORY is vacuously green. Two herdr-child
  scenarios depend on this — the superseded watcher's run directory in fact
  survives on both runners (the watcher dies to herdr-child's own `set -e`
  before its cleanup). Filed as
  docs/issues/2026-08-28-001-assert-file-not-exists-on-a-directory-is-vacuously-green-in-bats-file.md.
- Bats failure detection is `set -eET`-shaped and bash-version-dependent
  (mid-body `[[ ]]`/`(( ))` false is inert on bash 3.2 — existing issue
  2026-08-27-002). The shim reproduces it with an errtrace ERR trap running
  under the same interpreter; helper-depth failures are red on both runners
  (probe-verified).
- Three scripts.bats scenarios execute `bats` at runtime (nested-runner
  self-tests); one of them re-runs a filter against tests/scripts.bats itself.
  A full migration therefore keeps bats installed and keeps that .bats file
  present, or must change what those scenarios test.
- The suite itself leaks orphaned herdr-child watchers nondeterministically
  under BOTH runners; the cleanup gate treats this class as oracle-stochastic
  and gates only on bashunit-only leak classes outside the allowlist. This
  experiment's diagnosis also found 12 accumulated orphans on the host
  machine from earlier runs.
- Bats exports `BATS_TMPDIR` (= `$TMPDIR`); helpers use
  `${BATS_TMPDIR:-/tmp}`. The shim initially did not export it, which split
  identical debris across `/tmp` vs `$TMPDIR` and masqueraded as a
  bashunit-only leak. Fixed; the shim now exports it exactly as bats does.
- The widened leak monitoring exposed a pre-existing suite bug: hts test
  teardown races a surviving engine process that recreates
  `$HTS_STATE/sockets` after `rm -rf`, shedding one `hts.XXXXXX` dir per
  affected test under BOTH runners (2490 historical bats-shed dirs found
  under `$TMPDIR`). Filed as docs/issues/2026-08-29-001.

## Platform results

- macOS (host-safe, 390 scenarios): per-scenario parity OK for all four
  files under the hardened leak harness; both runners exit 0.
- Ubuntu/Docker (full mode, incl. real `chezmoi apply` idempotent
  scenarios): 400/400 parity pre-rebase; final pass on the rebased oracle:
  **403/403** (platform 2, palette 57, smoke 74, scripts 257,
  idempotent 13), both runners exit 0 on every file.

## Performance

`tests/bashunit/bench-bats-vs-bashunit.sh`: interleaved paired repetitions
(bats/bashunit alternating), orphan reaping between halves, a repetition
counts only if both halves exit 0.

- **Host, host-safe mode, 3 reps** (macOS arm64; constant background load
  from a runaway single-core process, identical for both halves):
  bats raw [137209, 138872, 140268] median 138872 ms (MAD 1396, CV 0.9%);
  bashunit raw [107307, 105276, 105417] median 105417 ms (MAD 141, CV 0.9%);
  **%change −24.1% — improvement beyond noise.**
- **Docker, full mode (incl. real-apply idempotent), 3 reps, final oracle
  (403 scenarios)**: bats raw [81457, 77497, 80625] median 80625 ms
  (CV 2.1%); bashunit raw [61511, 60863, 60966] median 60966 ms (CV 0.5%);
  **%change −24.4% — improvement beyond noise**, all exits 0. (An earlier
  pre-rebase 400-scenario run measured −24.2% with the same shim.)

## Cleanup evidence

Leak checks (process + tmp-path snapshots, class-normalized with per-class
counts) run around every side-by-side comparison; negative controls prove
both that they fire (control 6) and where they are blind by design
(control 7). The parity claim is scoped: **bashunit introduces no new leaks
within the monitored classes** (herdr daemons, sleep timers, bun trees,
`python3 -` drivers, stub dirs, hts./palette./tmp. and harness tmp paths,
chezmoi test config). Classes shed by the oracle itself (herdr-child
watchers, sweep-daemon, hts.X state dirs) are allowlisted with recorded
evidence and reported with counts rather than gated.

## Maintenance cost

- `tests/bashunit/bats-compat.bash` (~530 lines) is the single carrying
  cost: it re-implements measured Bats semantics (ERR-trap failure shape,
  `run` capture, assert vocabulary incl. `--separate-stderr`/stderr asserts,
  skip, tmpdir contract). New Bats idioms adopted in tests must be added
  here — the rebase during the experiment required exactly that
  (three `--separate-stderr` scenarios), a ~60-line addition found
  immediately by the per-scenario verifier.
- `scripts/bats2bashunit.py` converter + manifest keep the migration
  mechanical and re-runnable; drift is detectable by re-converting.
- Three scripts.bats scenarios execute `bats` at runtime, so bats remains a
  test dependency even after a switch (and `tests/scripts.bats` must remain
  present for one of them).

## Migration performed?

Yes. `tests/run-post-apply.sh` now converts the .bats files on the fly and
executes them with the pinned `tests/lib/bashunit` (0.50.1,
checksum-verified single file committed to the repo). Design choices:

- **The .bats files remain the single source of truth.** Conversion is
  deterministic and takes under a second, so the generated
  `tests/bashunit/*_test.sh` + `manifest.tsv` are gitignored build
  artifacts, not committed duplicates — no drift surface.
- The runner interface (`full|host-safe`) and every call site (Makefile,
  docker-compose, CI workflows) are unchanged.
- Execution shape mirrors the old `bats --jobs 8
  --no-parallelize-across-files`: sequential across files, 8 workers within
  a file (`MMS_BASHUNIT_JOBS` overrides), idempotent.bats serialized.
- bats remains a test dependency (three scenarios execute it at runtime).

Follow-on changes the switch surfaced:

- `tests/test_post_apply_suite_contract.py` asserted the exact bats argv by
  intercepting `bats` on PATH; it now records invocations of the bashunit
  binary via a `MMS_BASHUNIT_BIN` override and additionally asserts the
  wrapper regenerates converted files from the .bats sources.
- `docker/docker-compose.yml` staging now mounts and copies
  `scripts/bats2bashunit.py` into the container worktree.
- `make lint` excludes generated `*_test.sh` artifacts and `.context/`
  working state from shellcheck.
- The CI parallel-prerequisite assertions (bats ≥ 1.5, flock/shlock) remain:
  bats is still installed and still true; loosening them was not worth
  unverifiable CI churn.

Post-switch verification: host-safe run rc=0 (390 tests, 0 failures), all
8 negative controls pass, contract tests and `make test-issues` (45/45)
green, `make lint` rc=0, and a full `make test-ubuntu` Docker run through
the switched runner.
