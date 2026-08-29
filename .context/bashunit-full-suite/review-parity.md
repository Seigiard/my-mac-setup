# Parity review — bats→bashunit migration (static, 2026-08-28)

Independent correctness review of shim/converter/verifier/harness against the
oracle suite and the real bats-core 1.14 + bats-assert/bats-file sources.
STATIC ONLY: no suite, bats, bashunit, or docker was run. Two classes of
evidence were used: source reading (including the installed
`/opt/homebrew/Cellar/bats-core/1.14.0/libexec/bats-core/*` and
`tests/helpers/bats-libs/*/src/*.bash`) and trivial `/bin/bash -c` trap probes
(no test files touched).

Verified-good first (so reruns don't re-litigate them):

- **Converter round trip is byte-exact for all 5 files.** Independent reverse
  mapping (strip header/hook block, map `function test_NNN_slug(){` +
  `_bats_test_init N 'name'` back to `@test "name" {`) reproduces each oracle
  file exactly (smoke 1034, scripts 6436, palette 1067, platform 33,
  idempotent 179 body lines). Heredocs, nested-bats scenarios (scripts.bats:2747,
  2419), BATS_TEST_NUMBER users, and inline `teardown; setup` sites are verbatim.
- All 400 `^@test` lines match the converter's strict `TEST_RE`; none deviate.
- manifest.tsv: 400 rows, per-file counts match `grep -c '^@test'`; no
  duplicate (file,name) pairs.
- `idempotent_test.sh` carries `# bashunit: no-parallel-tests` on line 2;
  bashunit's parser (tests/lib/bashunit:8098) actually matches the marker on
  ANY line, so placement is satisfied with margin.
- `$lines` splitting parity: bats 1.14 uses `IFS=$'\n' read -d '' -r -a`
  (test_functions.bash:178) — read-based, no glob expansion, empty lines
  dropped. Shim's `set -f` + IFS split (bats-compat.bash:98-108) is equivalent.
- Trailing-newline stripping and merged 2>&1 capture: parity.
- Teardown semantics: bats calls `teardown ... || status=$?`
  (bats-exec-test:98), so errexit is OFF inside teardown and only its final
  status counts — exactly the shim's `_bats_run_teardown` contract.
- bats-file `-f`/`-d`/`-x` predicates and `stat -f '%A'`/`-c '%a'` in
  assert_file_permission match the real sources, including the vacuous
  `assert_file_not_exists`-on-directory behavior the herdr-child scenarios need.
- No `run` flags (`-N`, `!`, `--separate-stderr`, `--keep-empty-lines`), no
  bare `assert_output`/`refute_output`, no `assert_not_equal`/`assert_regex`/
  `assert_stderr*` anywhere in the 5 oracle files.

## HIGH

### H1. Failure-detection depth: shim misses failures inside helper functions

- Where: tests/bashunit/bats-compat.bash:26-39 (`_BATS_ERR_TRAP`, bare trap, no
  `set -eE`), vs bats-exec-test:2 (`set -eET` — errexit + errtrace active
  through the whole test body and every function it calls).
- Under bats, an unguarded failing simple command INSIDE a helper function
  (hts_setup, hts_run, child_stub_herdr, inline `teardown`/`setup` calls, any
  common.bash helper) aborts the test immediately via errexit, even when a
  later command in that helper succeeds. Under the shim, the bare ERR trap does
  not fire at nested-function depth (probe: `init(){ trap ... ERR; };
  helper(){ [ 1 -eq 2 ]; echo h-cont; }; t(){ init; helper; }` prints h-cont and
  returns 0 on /bin/bash 3.2). The shim only fails when the helper's *return
  status* is nonzero at the body-level call site.
- Impact: a whole class of regressions (helper's internal command starts
  failing but the helper's last command still succeeds) turns red under bats
  and stays green under bashunit. Invisible to per-scenario parity on a green
  suite — every current scenario passes on both sides either way.
- Repro idea (do not run now): add `false` followed by `:` mid-way inside
  `hts_setup` in a scratch copy; bats marks every hts test failed, the shim
  passes them. A permanent negative-control fixture with a deep-helper failure
  would pin this.
- Note: the `[[ ]]`/`(( ))` bash-3.2 inertness (docs/issues/2026-08-27-002) is
  a separate, correctly-mirrored quirk; this finding is about *simple commands
  in nested functions*, where bats is strict and the shim is not.

### H2. Shim's ERR-trap-depth trick is bash-version-sensitive; unverified on bash 5

- Where: bats-compat.bash:391-403 — the trap is armed inside
  `_bats_test_init`, a *callee* of the test function, and is expected to fire
  for failures in the *caller* (the test body). Probes confirm it does on
  macOS bash 3.2 (and the 400/400 host parity corroborates), but POSIX/bash
  leave ERR-trap firing at caller depth without `-E` underspecified, and no
  bash ≥4 was available on the host PATH to probe.
- Impact: if bash 5 (Docker/ubuntu, phase 7) does not fire the trap at body
  depth, EVERY body-level assertion failure becomes inert there and the whole
  Docker comparison silently degrades to last-command-status detection —
  which a green suite again cannot distinguish.
- Repro idea: in the Docker phase, before comparing suites, run the two
  one-line trap probes from this review under the container's bash and under
  `tests/lib/bashunit`'s interpreter; also run the negative-control file in
  Docker (its failing scenario exercises assert exit, not the trap — add a
  control whose failure relies ONLY on the ERR trap, e.g. `run false` +
  `[ "$status" -eq 0 ]` as the non-final line, then a succeeding `:` last).

## MEDIUM

### M1. run() capture: file vs pipe changes blocking and late-writer semantics

- Where: bats-compat.bash:77-96 (subshell + tempfile) vs
  test_functions.bash:398 (`output="$(...)"` — a pipe).
- Documented as deliberate (SIGPIPE of detached continuations), but it is an
  oracle divergence, not an emulation: (a) bats blocks in the command
  substitution until every process holding the write end of the pipe exits —
  a daemon that inherits stdout stalls bats (or its post-exit writes are
  captured); the shim returns as soon as the direct child exits. (b) Under the
  shim a daemon can keep writing into the capture FILE after `run` returns; a
  write that lands before `output=$(< file)` is nondeterministically included.
  (c) fd 1 of the run command is a regular file, not a pipe (`[ -p ]`, buffering
  mode, `stat` of /dev/stdout differ).
- Impact: scenarios that today pass on both sides can differ in *timing* and
  in which bytes land in `$output` the day a script regresses into leaving a
  child attached to stdout — bats would hang/fail, the shim would pass.
- Repro idea: `run bash -c '{ sleep 2; echo late; } & exit 0'` — bats waits
  ~2s and captures "late"; the shim returns immediately with empty output.

### M2. Leak gate's path snapshot is largely inert on macOS

- Where: tests/bashunit/compare-suite-file.sh:33-35 (`snapshot_tmp` watches
  only `/tmp/htspwn*`, `/tmp/bats-compat-run.*`, `/tmp/bats-run-*`).
- The shim's tmproot is `mktemp -d "${TMPDIR:-/tmp}/bats-compat-run.XXXXXX"`
  (bats-compat.bash:410) and on macOS `TMPDIR=/var/folders/...`, so the shim's
  own debris — and bats' run dirs, and palette's `${BATS_TMPDIR:-/tmp}`
  workdirs on the bats side — are all created OUTSIDE the watched globs. Only
  `/tmp/htspwn*` is genuinely monitored. The path half of the leak-parity gate
  therefore proves much less than it appears to (the earlier `pgrep -E` inertness
  fix did not reach this).
- Repro idea: make the bashunit side leak `"$BATS_TEST_TMPDIR/leftover"` or a
  `bats-compat-run.*` root (skip `_bats_file_cleanup`) — the gate stays green.
- Additionally, `normalize_leaks` (lines 39-45) collapses digits/hashes to
  classes, so "bats leaked 1 watcher, bashunit leaked 5 of the same class"
  compares equal. Count-insensitive by design; worth stating in the verdict.

### M3. Zero-arg assert_output/refute_output semantics are inverted vs bats-assert

- Where: bats-compat.bash:185-227 vs bats-assert/src/assert_output.bash:183-217.
- Real: bare `assert_output` = "output must be NON-empty"; bare `refute_output`
  = "output must be empty". Shim: zero args fall through to exact-match against
  `""` — i.e. `assert_output` asserts output IS empty, the exact opposite; and
  `refute_output` asserts non-empty.
- No current call site uses the bare form (grepped all 5 files), so parity runs
  cannot see it — but any future test written against bats-assert docs would
  silently assert the inverse under the shim. Also missing: real's
  `-p`/`-e` mutual-exclusion error.
- Repro idea: `run true; assert_output` — real bats fails ("no output"), shim
  passes.

### M4. Converter hook wrappers swallow setup_file/teardown_file failures

- Where: scripts/bats2bashunit.py:90-100. `set_up_before_script` emits
  `setup_file` followed by `:` — a nonzero setup_file is discarded and every
  test runs anyway (bats fails the whole file). `tear_down_after_script` runs
  `teardown_file` then `_bats_file_cleanup`, so teardown_file's status is
  replaced by cleanup's.
- Latent today: none of the 5 files defines setup_file/teardown_file (grep
  confirms; idempotent.bats mentions setup_file only in a comment). But the
  converter is generic and the failure mode is exactly the kind status parity
  cannot see (a broken setup_file usually makes tests fail for OTHER reasons —
  or worse, pass vacuously).
- Repro idea: convert a scratch .bats with `setup_file(){ false; }` and one
  trivially-green test; bats reports the file failed, bashunit passes.

## LOW

### L1. Invalid ERE in refute_* --regexp passes under the shim

- bats-compat.bash:177-183: `[[ $2 =~ $3 ]]` with an invalid regex returns 2,
  which `refute_output`/`refute_line -e` treat as "no match" → PASS. Real
  bats-assert routes through `__check_is_valid_regex` and errors the test.
  Current regexes (`^export PATH=` etc.) are static and valid. Repro:
  `refute_output --regexp '['`.

### L2. assert_file_contains differs in `--` and engine validation

- bats-compat.bash:356-367 passes `grep -q -- "$regex"`; real bats-file
  (file.bash:558) has no `--` (leading-dash regex errors under real, matches
  under shim) and enforces a grep/egrep/pcregrep allow-list the shim skips.
  All current call sites use the default engine and dash-free regexes.

### L3. fail() drops extra args and never reads stdin

- bats-compat.bash:116-121 prints only `${1:-}`; real fail() prints all args
  and, with zero args, reads the message from STDIN (error.bash). Message-only
  divergence (status parity preserved); idempotent.bats:172 redefines fail
  locally anyway.

### L4. assert_line/refute_line arg handling laxer than real

- bats-compat.bash:229-245: `--index` accepts non-integers (real validates and
  errors), `-p` + `-e` together is last-wins (real errors), and a negative
  index silently switches to search mode (real indexes the array). None
  triggered by current call sites.

### L5. BATS_TMPDIR is never set by the shim

- palette.bats:24 `${BATS_TMPDIR:-/tmp}` → `/tmp` under the shim vs
  `$TMPDIR` (/var/folders) under bats. Behavior-equivalent today but the two
  runners scatter work dirs in different places (feeds M2), and any future
  test asserting on the path diverges.

### L6. Verifier TAP parsing trusts names to avoid TAP metacharacters

- verify_bats_bashunit.py:27-49: a scenario name containing `" # skip"` (bats
  side) or `" # SKIP"`/`" - "+SKIP` combos (bashunit side) would misparse
  status or reason. All 400 current names are clean; a cheap guard would be a
  converter assertion rejecting `#` in test names. Also `bats ... 2>&1` into
  the TAP file (compare-suite-file.sh:85-86) lets stray stderr lines shaped
  like `ok N ...` inject phantom results — exotic, and dup detection would
  usually flag it.

### L7. Converter TEST_RE strictness is unguarded

- scripts/bats2bashunit.py:23: only `@test "name" {` exactly. A single-quoted
  name, trailing space, or trailing comment would leave the @test line (and
  its body) executing at file scope in the generated file; a heredoc line of
  the exact shape at column 0 would be wrongly converted. Today all 400 lines
  conform (verified) and a miss surfaces as MISSING-IN-BASHUNIT at compare
  time — but a post-convert assertion (`grep -c '^@test' == manifest rows`)
  would fail fast instead.

### L8. Duplicate scenario name across files

- "python3 is present and at least 3.9, the floor README.md declares" exists
  in two files (manifest.tsv). Harmless for the per-file verifier (keys are
  scoped by --bats-file); a future combined-TAP comparison would collide.

### L9. run() before _bats_test_init writes to an unset BATS_TEST_TMPDIR

- bats-compat.bash:89: a `run` from a future setup_file/set_up_before_script
  context would target `"/.bats-run-out.$$..."` and fail the capture. bats
  falls back BATS_TEST_TMPDIR→BATS_FILE_TMPDIR→BATS_RUN_TMPDIR
  (test_functions.bash:364). Latent (no setup_file today).

### L10. Exit-code gate only fires when exactly one side is 0

- compare-suite-file.sh:120-123: bats=1 vs bashunit=2 passes the gate.
  Deliberate-looking; per-scenario verification covers the statuses, so this
  is informational only.

## Cross-cutting observation for the verdict

Per-scenario status+skip parity on an all-green suite proves the shim does not
*break* passing tests; it cannot prove the shim *detects* what bats detects.
The negative controls cover one assert-exit path (assert_output) plus leaks.
H1/H2/M1/M3 all live in the undetectable region. Recommended cheap additions
before the verdict: a deep-helper-failure control, a trap-depth probe run per
interpreter (esp. Docker bash 5), a bare-`assert_output` control, and a
shim-side path-leak control under $TMPDIR (not /tmp).
