# Cleanup / leak-evidence review (static, independent)

Scope: tests/bashunit/compare-suite-file.sh, tests/bashunit/bats-compat.bash,
scripts/run-negative-controls.sh, five oracle .bats files + helpers,
.context/bashunit-full-suite/status.md. No suites were executed (verification
runs in flight); every claim below is from reading the code.

Verdict summary: the gate soundly detects leaks **within the classes it
monitors** (the leak negative control remains valid under the directional
gate), but the monitored surface is a minority of the suite's actual spawn/
write surface, and the KNOWN_STOCHASTIC allowlist is rate- and count-blind.
The evidence therefore supports a qualified claim — "bashunit introduces no
new leaks in the monitored classes" — not a blanket "no new leaks" claim.

---

## HIGH

### H1. LEAK_PATTERNS misses most of the suite's spawned process classes

`tests/bashunit/compare-suite-file.sh:20` — `LEAK_PATTERNS='htspwn|herdr|sweep-daemon|chezmoi-test'`
is matched against full command lines (`pgrep -lf`/`-af`). Grepping the five
oracle files for backgrounding constructs shows several classes whose command
line matches none of the four patterns; a bashunit-introduced leak in any of
them is invisible to the gate on both the proc and the parity side:

- Bare `sleep 30` deadline timers / fake lock owners:
  `tests/scripts.bats:4382` (`(sleep 30; : > "$deadline") &`),
  `tests/scripts.bats:5881`, `tests/scripts.bats:5939` (fake sweep-lock
  owners). Cmdline is `sleep 30` — unmatched.
- Backgrounded subshells / brace groups / shell functions that never `exec`:
  the reconcile reader loop `tests/scripts.bats:3048` (`) &`), the fifo
  feeder `tests/scripts.bats:3373`, the forked wrappers around
  `hts_worker_run &` (`tests/scripts.bats:3129,3137`) and
  `hts_presentation_run &` (`tests/scripts.bats:4371`). A forked-but-not-
  exec'd bash keeps the **parent runner's** cmdline
  (`bats-exec-test …/tests/scripts.bats` or `bash tests/lib/bashunit …`) —
  neither contains any pattern. The reader loop is exactly the process the
  suite itself documents as an infinite-spin hazard
  (`tests/helpers/herdr_task_sync.bash:56-66`, HTS_READER_PID); if the
  bashunit tear_down path ever fails to run hts_teardown, that orphan is
  undetectable by this gate.
- `python3 -` heredoc drivers (cmdline is literally `python3 -`):
  `tests/scripts.bats:957,1016,1077,1115,1933,2499,3230,3453` and others
  (10 sites in scripts.bats alone); several use
  `subprocess.Popen(..., start_new_session=True)`
  (`tests/scripts.bats:3242,3459`). The herdr-child *they* launch is
  pattern-visible, but the driver itself and any non-herdr child is not.
- `bun test` trees: `tests/smoke.bats:909,919` spawn whole Bun suites;
  neither `bun` nor its children match any pattern.
- Engine/model stubs living under `hts.XXXXXX`: `HTS_STUB="$HTS_WORK/stub"`
  where `HTS_WORK=${BATS_TMPDIR:-/tmp}/hts.XXXXXX`
  (`tests/helpers/herdr_task_sync.bash:70-71`). The backgrounded `pi` stubs
  at `tests/scripts.bats:2795,2798` run as `/tmp/hts.abc123/stub/pi` —
  contains neither `htspwn` nor `herdr`. Same for the fake `zed` stubs under
  `palette.XXXXXX` (`tests/palette.bats:24`).

Consequence: the directional gate can only prove parity for herdr-child,
herdr-task-sync (source path), htspwn-named, and chezmoi-test processes.
Everything above passes silently even if bashunit leaks it deterministically.

### H2. snapshot_tmp globs miss the very tmp classes the suite is known to shed

`tests/bashunit/compare-suite-file.sh:40-44` globs only
`/tmp/htspwn*`, `bats-compat-run.*`, `bats-run-*` (in /tmp and $TMPDIR).
Fixed/templated paths the suite actually creates and that fall outside the
globs:

- `${BATS_TMPDIR:-/tmp}/hts.XXXXXX` — every scripts.bats hts test
  (`tests/helpers/herdr_task_sync.bash:70`).
- `${BATS_TMPDIR:-/tmp}/palette.XXXXXX` — every palette test
  (`tests/palette.bats:24`).
- Bare `mktemp -d` dirs (default template `tmp.XXXXXX` under $TMPDIR, i.e.
  /var/folders on macOS): `CHILD_STUB` at `tests/scripts.bats:163,389`,
  `stubdir` at `tests/scripts.bats:63`, `no_child` at
  `tests/scripts.bats:237`, `tests/smoke.bats:247,826`. This is precisely
  the class that produced the **680 stale stub dirs** recorded in
  `status.md:87` — observed machine debris of a class the path gate cannot
  see.
- `/tmp/chezmoi-test.yaml` (`tests/helpers/common.bash:66`) — matched by the
  *proc* pattern `chezmoi-test` but by no tmp glob.

A bashunit-side teardown regression that stops removing HTS_WORK,
PALETTE_WORK, or CHILD_STUB would leave the exit code, the parity verifier,
and both leak checks green.

### H3. The KNOWN_STOCHASTIC allowlist is rate- and count-blind

`tests/bashunit/compare-suite-file.sh:115-118`. Two compounding properties:

- `normalize_leaks` ends in `sort -u` (line 53): 50 leaked watchers and 1
  leaked watcher normalize to the same single class line. Count information
  is discarded before the gate sees it.
- `grep -Ev "$KNOWN_STOCHASTIC"` excuses **any** bashunit-only line
  containing the substrings, unconditionally, on every run.

Combined: a shim bug that deterministically leaks a watcher (or many) on
*every* run is byte-identical, at the gate, to the oracle's occasional
stochastic orphan. Nothing in the harness measures or compares leak *rates*
across runs, so "oracle-stochastic" is an assumption the gate can never
falsify for these two classes. The gate comment (lines 112-114) even claims
observations ("bats-only, both-sides, and bashunit-only across repeated
runs") that status.md does not fully record — see M3.

---

## MEDIUM

### M1. collect_leaks' settle-retry exits on the first clean snapshot — slow-to-appear leaks are invisible

`tests/bashunit/compare-suite-file.sh:63-74`. The loop returns success the
moment a post-snapshot equals the pre-snapshot; the first snapshot is taken
immediately after the runner exits. A leak that *appears* after that instant
— a double-forked daemon whose intermediate parent is still mid-exec, an
`--ensure-daemon` respawn (`home/dot_local/bin/executable_herdr-task-sync:1927`
nohup-double-forks), a watcher armed by a still-settling teardown — is never
seen. The retry mechanism only tolerates slow *disappearance* (teardown TERM
latency), never slow *appearance*; total observation window is at most ~4s
and typically ~0s.

### M2. Negative controls have no case for the two known blind spots

`scripts/run-negative-controls.sh:128-164`. Control 6 injects an
`htspwn-negctl-sleep` process + `/tmp/htspwn-negctl-leak` path — both inside
the monitored patterns/globs and outside KNOWN_STOCHASTIC, so it does still
prove detection under the directional gate (bashunit-only, not allowlisted →
`LEAK-PROCESS`/`LEAK-PATH`, rc≠0). Missing:

- An expected-**pass** control injecting a bashunit-only process matching
  `herdr-child __watcher` — to pin down and document that the allowlist hole
  exists and is accepted (today its scope is only implied by the gate code).
- An expected-**fail-that-passes** demonstration for H1/H2: injecting e.g. a
  leaked `sleep 300` or an unremoved `hts.XXXXXX` dir would show the gate
  green on a real leak. Its absence lets "ALL NEGATIVE CONTROLS PASS"
  (status.md:85) read as broader detection coverage than the harness has.

On whether the allowlist hole is acceptable (question posed both ways):
*For*: the oracle demonstrably sheds watchers itself (status.md:86,103 —
symmetric LEAK-BOTH, ambient debris from aborted runs); gating on that class
would make the comparison flaky and would penalize bashunit for pre-existing
suite behavior; the migration claim is about not being *worse*.
*Against*: with no rate measurement, "not worse" is unproven — the gate
accepts a bashunit that leaks a watcher every run against an oracle that
leaks one per hundred. Acceptability therefore depends on evidence the
harness does not collect. Minimum honest position: keep the allowlist but
(a) log counts per class before `sort -u`, (b) aggregate watcher-leak
frequency per runner across the repeated runs already planned (the flake-rate
measurement status.md:103 calls for), and cite that in the verdict.

### M3. status.md observations do not fully support the gate comment's classification

Gate comment (`compare-suite-file.sh:112-114`) asserts the stochastic classes
were "observed bats-only, both-sides, and bashunit-only across repeated
runs". Recorded evidence:

- watcher class: both-sides symmetric (status.md:103 run1), ambient debris
  attributed to *bats* runs/aborts (status.md:86). A **bashunit-only**
  watcher observation is not recorded anywhere in status.md.
- `herdr-task-sync --sweep-daemon`: exactly **one** observation, bats-only
  (status.md:103 run2a). Allowlisting a class from a single occurrence is
  defensible as a directional-gate design (bats-only never gates anyway; the
  entry only matters if bashunit ever leaks it), but the "oracle-stochastic"
  label is extrapolated from n=1.

The watcher classification is *plausibly* justified (two independent
both-sides/oracle observations, mechanism understood: launcher death); the
sweep-daemon entry and the "bashunit-only observed" claim are not backed by
the written record. Either record the missing observations or soften the
comment — the review trail is part of the migration evidence.

### M4. Ambient exclusions create two narrow but real hiding places

`tests/bashunit/compare-suite-file.sh:35-37`:

- `'\.local/bin/h[e]rdr-task-sync'` excludes **all** deployed-path engine
  processes. Tests run the engine from SOURCE_ROOT
  (`executable_herdr-task-sync`), so test-spawned engines stay visible — but
  any test that reaches the deployed binary via PATH/HOME (smoke.bats asserts
  against the deployed `~/`) would have its leak excused as ambient.
- `'^[0-9][0-9]* h[e]rdr$'` hides a leaked stub `herdr` invoked with **no
  arguments** (indistinguishable from the interactive session). Stubs are
  normally invoked with args (`herdr agent list …`) and remain visible, so
  exposure is small.

`compare-suite-file` self-exclusion (line 35) is safe: children exec'ing
other binaries lose the string; children forking without exec are already the
runner-cmdline class of H1.

---

## LOW

### L1. Normalization fails to collapse mktemp suffixes for the harness's own tmp classes

`normalize_leaks` (`compare-suite-file.sh:48-53`) collapses `tmp.XXXXXX` but
not `bats-compat-run.XXXXXX` / `bats-run-XXXXXX` (only digits inside the
random suffix become N; letters survive). Symmetric leaks of the same class
on the two sides would normalize to *different* strings and be reported as
bashunit-only → gate failure. This can only over-fail (conservative), never
hide a leak; worth fixing to avoid a spurious red during verification runs.

### L2. bats-compat crash paths leak the file tmproot — but into a monitored glob

`tests/bashunit/bats-compat.bash:428-432` — `_bats_file_cleanup` runs only
via the generated `tear_down_after_script`. If a bashunit worker dies without
reaching it (SIGKILL, harness timeout), `${TMPDIR}/bats-compat-run.XXXXXX`
persists, including every `run()` capture file (`.bats-run-out.$$.$SEQ`,
line 94 — accumulated per test, never pruned mid-file). Both /tmp and
$TMPDIR spellings of this class **are** in snapshot_tmp, so the gate detects
it; this is a cleanup-robustness note, not a blindness hole. The teardown
first-failing-command deviation is documented in-file (lines 436-438) and
matches the suite's `||`-guarded teardowns; `skip`'s `exit 0` path and the
ERR-trap `exit` path both hand control back to bashunit, which still runs
tear_down (the file states this as measured behavior — accepted as recorded,
not re-verified here).

### L3. reap_orphan_watchers only reaps dead-launcher watchers

`compare-suite-file.sh:82-88`. A watcher whose launcher is still alive
survives into the bashunit half's pre-snapshot. This is harmless for
detection (new_entries diffs raw lines, so a new bashunit watcher is still a
new pid/line), and pre-existing entries that die mid-half are ignored by the
additions-only diff. Only effect: the settle loop can burn its full 4s when
a baseline process exits during the half.

---

## Verdict on the migration claim

The chain **detects what it watches**: pre/post raw-line diffing is sound,
the directional gate correctly fails on non-allowlisted bashunit-only
classes, and negative control 6 genuinely exercises that path even after the
directional change. Within the monitored classes (herdr-child, source-path
herdr-task-sync, htspwn, chezmoi-test procs; htspwn/bats-run/bats-compat-run
paths), a parity claim is supported.

It does **not** support an unqualified "bashunit leaks nothing bats does
not": (H1/H2) most of the suite's spawn and tmp-write surface is outside the
patterns/globs — including the mktemp-dir class with 680 observed debris
instances; (H3/M2) the watcher/sweep-daemon allowlist is unfalsifiable by
this gate and has no rate evidence behind it; (M1) leaks appearing after
runner exit are unobservable. Recommended before the verdict doc: widen
LEAK_PATTERNS (+`hts\.`, `palette\.`, `sleep [0-9]`, `bun test`, `python3 -`
scoped to test-window pids if noise allows) and snapshot_tmp (+`hts.*`,
`palette.*`, `/tmp/chezmoi-test.yaml`), log per-class counts pre-`sort -u`,
and fold watcher-leak frequency per runner into the planned flake-rate
measurement. With those, the same harness can carry the full claim.
