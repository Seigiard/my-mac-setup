# bashunit full-suite migration experiment

Status: IN PROGRESS — this skeleton is filled in as phases complete.
Working state: `.context/bashunit-full-suite/status.md` (not committed to main docs).

## Question

Can the full production post-apply shell-test suite (`tests/run-post-apply.sh`:
smoke, scripts, palette, platform, idempotent — 400 scenarios) migrate from
Bats 1.14 to bashunit 0.50.1 with behavior preserved and wall-clock time
reduced? The Bats files are the immutable behavioral oracle.

## Verdict

TBD — one of `bashunit-full-suite-win | -neutral | -rejected | -inconclusive`.

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
  control.

## Scenario coverage

| file | scenarios | macOS parity | Ubuntu parity (full mode) |
|---|---|---|---|
| platform.bats | 2 | OK | OK |
| palette.bats | 57 | OK | OK |
| smoke.bats | 74 | OK | OK |
| scripts.bats | 254 | OK | OK (one scenario flake-rate under measurement) |
| idempotent.bats | 13 | OK (guard/skip mode) | OK (real chezmoi apply) |

Independent coverage review reconciled the manifest exactly in both
directions (400/400, verbatim skip messages, no duplicates).

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
  under BOTH runners (observed bats-only, both-sides, and bashunit-only across
  repeated runs); the cleanup gate treats this class as oracle-stochastic and
  gates only on bashunit-only leaks outside it. This experiment's diagnosis
  also found 12 accumulated orphans on the host machine from earlier runs.

## Platform results

TBD (macOS per-file comparisons in progress; Ubuntu pending).

## Performance

TBD — `tests/bashunit/bench-bats-vs-bashunit.sh`: 3+ interleaved paired
repetitions per mode, quiet machine, only clean runs count; raw durations,
median, MAD, CV, %change.

## Cleanup evidence

TBD — leak checks run around every side-by-side comparison; negative control
proves they fire.

## Maintenance cost

TBD.

## Migration performed?

TBD.
