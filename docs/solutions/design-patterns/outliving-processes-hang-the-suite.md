---
title: A process that outlives its test hangs the suite instead of failing it
date: 2026-09-03
last_updated: 2026-09-06
category: design-patterns
module: testing
problem_type: design_pattern
component: testing_framework
severity: high
root_cause: test_isolation
resolution_type: workflow_improvement
related_components:
  - tooling
  - ci
applies_when:
  - "A test or production path spawns a background worker, daemon, or detached process that can outlive its parent"
  - "Writing a wait loop that polls for a file, lock, or release marker"
  - "Writing teardown that removes a state directory another process may still be writing"
  - "A suite passes focused or on a workstation but stalls under --jobs or in Docker"
  - "Choosing where in a launcher to close inherited file descriptors before exec"
  - "Building a per-test temporary directory, capture file, lock, or marker name from a value that can repeat across tests"
symptoms:
  - "The runner prints every test as passing, then never returns; the container sits at 0.00% CPU with no timeout firing"
  - "A blocked descendant holds the runner's stdin or capture pipe, so the runner waits on an EOF that never arrives"
  - "Orphaned pollers accumulate across runs and inflate the machine's own benchmark numbers before anything goes red"
  - "A test passes focused and on a workstation but fails or stalls under parallel load, in CI, or in Docker"
  - "Teardown removes a state directory and a surviving writer immediately recreates part of it"
  - "An assertion reads output that belongs to an unrelated test, so the failure names a case that never produced that text"
tags:
  - process-lifetime
  - inherited-descriptors
  - test-hang
  - detached-worker
  - teardown-race
  - shared-temp-path
  - test-identity
  - sigpipe
  - bash-3-2
  - bashunit
---

# A process that outlives its test hangs the suite instead of failing it

## Context

Between 2026-08-24 and 2026-09-03 this repository closed nine separate incidents that
look unrelated in a list — a macOS hang, a Docker stall, a tmp-dir pile, a CI-only
string mismatch, a Linux worker that never started — and share one shape: **something
a test started was still alive when the test finished.**

The failure mode is what makes the class expensive. A leaked process does not produce a
red assertion. It produces silence:

1. **2026-08-24, macOS.** `bats tests/scripts.bats` printed 74 passes, then sat inside
   test 75 for over 25 minutes. The same test passed instantly under `--filter`, which
   made it look order-dependent. It was not: the full suite inherited an interactive
   terminal on stdin and the filtered run got immediate EOF. A fail-open helper copied
   inherited stdin, so with a TTY behind it the copy never ended. SIGINT produced status
   130 and confirmed only 75 of 194 tests had run.
2. **2026-08-29, Docker.** `make test-ubuntu` froze for nine minutes at 0.00% CPU with
   the log ending on a passing line. The process tree held two `cat` processes blocked
   in `anon_pipe_read`, fd 0 pointing at the bashunit runner's own stdin pipe — whose
   write end nothing ever closed. Both owning tests had already reported green.
3. **2026-08-28 → 08-30, orphaned watchers.** Twelve `herdr-child __watcher` daemons
   polling at 10 ms had accumulated from repeated suite runs, each outliving the
   `--launcher-pid` process it was supposed to follow. Nothing failed. Full-suite wall
   time drifted 155s → 165s and host 141s → 161s within an hour (~7%) on baseline-tree
   control runs, quietly corrupting the benchmark the session was there to measure.
4. **2026-08-30 → 09-01, reap-owner guard.** `make test-ubuntu` blew a 20-minute
   harness limit after hundreds of green tests. The container showed a reap guard
   blocked 19 minutes waiting for a release file whose run directory had already been
   deleted. Five focused Ubuntu repeats passed; only the full `-j 8` contention profile
   reproduced it.
5. **2026-08-29/30, tmp shedding.** 2490 stale `hts.*` directories under `$TMPDIR` and
   138 under `/tmp`, growing 4–15 per suite run. Teardown `rm -rf`'d the work directory
   and a surviving engine process recreated `state/sockets` underneath it.

Two more incidents came from the *fixes*, which is why they belong in the same document:

6. **2026-09-03, the overcorrection.** Closing every `/dev/fd` entry inside the
   *launcher* subshell closed Bash's own internal state before `exec` under Linux
   `setsid`. The worker detached and returned control to the caller, then never reached
   its readiness barrier — a silent no-op rather than a hang.
7. **2026-09-03, EPIPE as a CI-only flake.** `herdr-peer-alias` read a 1024-member
   alias pool through a process substitution and exited at the first free candidate,
   closing the pipe with ~1000 lines unwritten. Under SIGPIPE's *default* disposition
   the producer dies silently — that is a workstation shell, which is why it always
   passed locally. Under an *inherited ignored* disposition the producer takes EPIPE
   and Bash writes `printf: write error: Broken pipe` once per unwritten line: 1019
   lines, onto the stderr that `bashunit`'s `run` captures into `$output`. CI run
   33754209087 (`test-macos`) failed comparing `ochre-bear` against `ochre-bear` plus
   that line.

An eighth incident belongs here for a different reason. It wears the same signature and
shares none of the cause, which is precisely what made the triage rule below incomplete:

8. **2026-09-05, a per-test path that was not per test.** `tests/bashunit/scripts_test.sh`
   failed the macOS `-j 8` job in four of five runs on one branch, in two unrelated cases,
   on trees differing only in files neither case reads; `test-ubuntu` passed every time.
   The loud symptom was a case asserting `strict pane-label sweep did not converge` and
   receiving a JSON document of MCP server entries instead — output belonging to a
   different case. Nothing had leaked and nothing hostile had been inherited. The `run`
   helper writes its capture under `$BATS_TEST_TMPDIR`
   (`tests/bashunit/test-dsl.bash:115`), and `BATS_TEST_TMPDIR` was built from the
   *historical Bats number* the converter carried over from the pre-bashunit suite. Those
   numbers repeat once suites are merged, so two cases sharing a number shared a capture
   directory, and under `-j 8` they could hold it at the same time. The directory looked
   per-test and was not.

The fix (PR #172) keys the directory on the runner's own per-test identity instead —
`BATS_TEST_TMPDIR="$_BATS_FILE_TMPROOT/$BASHUNIT_CURRENT_TEST_ID"`
(`tests/bashunit/test-dsl.bash:466`), where the runner exports a per-test ID derived from
the test function name (`tests/lib/bashunit:15983`). The same incident's quieter symptom —
`grep` exiting 2 on a `successful-prompts.log` that did not exist yet — belongs to rule 4
rather than here: the case waited for `event=settled-11` in `calls.log` and then read a
*different* file, so the wait cleared on a proxy. `child_wait_for_log` takes the file to
watch as its second argument (`tests/bashunit/scripts_test.sh:2561-2562`), and the
affected cases now pass the file the assertion actually reads.

**What this incident does not establish.** The fix was not re-verified against repeated
macOS CI runs under `-j 8`, so the original four-in-five failure rate is unconfirmed
post-fix. The regression probe added alongside it covers the collision, not the contention
profile the flake was observed under.

## Guidance

**1. Detaching means owning a session *and* holding no inherited descriptor.**
`setsid` alone is not detachment. Redirect stdio explicitly and close every numeric
`/dev/fd` entry other than 0, 1, 2, and 255 (Bash 3.2 reserves 255 for the script
itself). Agent harnesses and test runners routinely pass control pipes on descriptors
above stderr; a descendant that keeps one alive keeps the reader waiting.

```bash
close_inherited_descriptors() {
  local descriptor fd
  for descriptor in /dev/fd/*; do
    fd="${descriptor##*/}"
    case "$fd" in
      0 | 1 | 2 | 255 | *[!0-9]*) continue ;;
    esac
    eval "exec ${fd}>&-" 2>/dev/null || true
  done
}
```

**2. Close the descriptors in the process that becomes the worker, never in the
launcher.** The launcher subshell still needs its own descriptors to reach `exec`. In
`home/dot_local/bin/executable_herdr-worktree-identity` the closure runs at line 1010,
inside validated `--worker` mode after argument parsing — not in `detach_worker`
(lines 971–988), which only sets up the session and redirects stdio. `executable_herdr-pane-labels`
(lines 271–280) and the shared `home/dot_local/lib/herdr-process.sh` (lines 7–16, sourced
by `herdr-child-watcher.sh:117`) carry the identical helper for the same reason.

**3. Redirect on the consumer side too.** Any command in a test that does not read a
payload gets `< /dev/null`. Do not rely on the parent's stdin being harmless — it is a
TTY locally and a pipe in the runner, and only one of those ever reaches EOF on its own.
Shipped code has the mirror version of this rule, triggered by capture rather than by the
test context; see `capturing-child-output-hides-the-prompt.md`.

**4. Every wait loop needs abandonment exits, not just a success exit.** The success
condition is the one everybody writes. Three others decide whether the loop can hang:

- the owner is gone — `kill -0 "$launcher_pid" 2>/dev/null || fail ...`
- the state being waited on is gone — `[ -d "$run_dir" ] || exit 1`
- an absolute bound — `HERDR_CHILD_TEST_HOLD_TIMEOUT_SECONDS` (default 120s,
  `home/dot_local/lib/herdr-child-supervision.sh:269-270`)

Which one applies varies per loop, and the variation is the trap: a hold the launcher
legitimately outlives cannot use launcher liveness, so it needs the other two.

**5. Never classify "the error path itself failed" as transient.** The forever-poll
that every real orphan actually took was not a missing timeout. Teardown removed the run
directory, so the redirection writing `pane-get.err` failed, so the `pane_not_found`
grep matched nothing, so the branch that distinguishes fatal from retryable read every
iteration as retryable. `home/dot_local/lib/herdr-child-watcher.sh:243-248` now exits on
the missing directory *before* reaching that classification.

**6. Teardown reaps before it removes, then confirms the removal settled.** `rm -rf`
against a live writer is a race the writer wins. The working shape used three ledgers to
find what to reap — a fork-time spawn registry carrying process-start tokens so recycled
PIDs are never signalled, claim/lock owner records, and a `ps` scan for commands under
the sandbox path — then re-checked that the tree stayed deleted.

**7. Make stragglers fail closed.** Alongside the reap, the engine was changed to create
at most one directory level and never its ancestors. A writer that survives teardown
then fails instead of resurrecting the deleted tree.

**8. Put a guard at the suite boundary so the class fails loudly next time.**
`tests/run-post-apply.sh:133-178` fails the run when a watcher spawned from this checkout
survives with **both** a dead launcher and a missing run directory. Both criteria are
required: a dead launcher alone is the normal terminal state of an armed detached
watcher, so a concurrent run's legitimately held watcher would be a false positive. PID
identity is re-verified immediately before TERM and again before KILL.

**9. Reproduce the inherited process attribute, not just the code path.** TTY-versus-pipe
stdin and the SIGPIPE disposition are inherited attributes. A focused local run silently
supplies the benign value of both, which is exactly why these bugs reach CI. Stand the
hostile value up deliberately — `trap '' PIPE` for the ignored disposition, a PTY-backed
harness for the terminal stdin — and prove the regression red before the fix.

**10. Prefer removing the pipe to handling the break.** `herdr-peer-alias:55-73` now
reads the pool with one command substitution and scans it from a here-string. No pipe
exists, so no writer can take EPIPE under any disposition — and the producer's exit
status stops being discarded, which fixed a second latent defect where a pool that
failed validation was reported as "alias pool is exhausted".

**11. A path is only as per-test as the value it is keyed on.** A temp directory, a
capture file, a lock, a marker — each is per-test only when its key is unique per test.
Verify the key, not the intent. A historical test number carried over by a converter, a
description slug, a wall-clock stamp, or a per-process counter is *usually* distinct, and
"usually distinct" is exactly what parallelism exists to break. Prefer an identity the
runner guarantees is unique per test over one that merely tends to be.

**12. Fix a shared-key defect in the DSL, not in the cases that happened to collide.**
`run` writes into `$BATS_TEST_TMPDIR` for every case in the suite, so the two cases that
went red were the two that got observed, not the two that were exposed. Patching them
would have left every other pair sharing a number holding one path — and would have left
the next merged suite free to add more.

## Why This Matters

A red assertion names its own file and line. This class names nothing. The 2026-08-24
hang cost 25 minutes before anyone knew the run was dead, the Docker stall nine minutes,
the reap-guard stall a full 20-minute harness limit — each ending in manual process-tree
archaeology (`ps -axo pid=,args=`, `/proc/<pid>/fd`, `docker top`) rather than in a test
report.

`make test-ubuntu` and `make test-docker` are the only targets in this repository that apply
the checkout before asserting (`docker/docker-compose.yml:116-117` and `:179-180`). While a hang is
reachable in them, no change to a managed file under `home/` can be proven at all — the class
blocks verification of unrelated work, not just its own.

The orphan-accumulation variant is worse than a hang because it never stops anything. It
degrades the machine and the measurements taken on it, so a performance session draws
conclusions from numbers a previous session's leaked pollers wrote.

The overcorrection matters just as much as the leak. "Close everything before exec" is
the obvious reading of rule 1 and it silently disabled a Linux worker: the launcher
returned success, nothing hung, and the work simply never happened.

## When to Apply

- Writing or reviewing any `&`, `setsid`, `nohup`, or `coproc` in a script that a test
  harness or agent may invoke.
- Writing a `while [ ! -f ... ]` / `while [ ! -e ... ]` loop of any kind.
- Writing teardown that deletes a directory another process holds open.
- Triaging a suite that passes focused and stalls **or fails** under `--jobs`, in Docker,
  or only on one CI runner. Three causes produce that one signature: an inherited
  attribute, a leaked process, and a shared path that only looks per-test. Rule out all
  three before suspecting test ordering.
- Writing or reviewing any temp directory, capture file, lock, or marker whose name is
  built from a test's own metadata.
- Reviewing a fix that closes descriptors: check *where* in the launch sequence it runs.

## Examples

Diagnosing a stalled runner — the descriptor set is the evidence, not the stack:

```
7475  bash tests/lib/bashunit -j 8 ... tests/bashunit/scripts_test.sh
48750 └─ cat            S  anon_pipe_read
       0 -> pipe:[99081821]      # the runner's stdin; nothing closes the write end
       2 -> /tmp/bats-compat-run.XXXXXX/test-119/.bats-run-out.7475.1
```

The `.bats-run-out` path names the owning test — though in this transcript it names it by
the historical Bats number (`test-119`), which incident 8 later showed was not a unique
key. The current leaf is the runner's per-test identity. Detection for the orphan variant is
`pgrep -f "herdr-child __watcher"`; cleanup is to kill each whose `--launcher-pid` process
is dead, read from `ps -o args= -p <pid>`.

A deliberately hostile fixture beats a hopeful one. `tests/bashunit/bashunit_late_output_probe_test.sh`
exists because a background child inheriting the captured stdout can append output *after*
bashunit's `##...##` payload line, which stock upstream 0.50.1 then parses as the result
line. The probe arranges that race on purpose — waiting on the test subshell's death
rather than sleeping, because the payload is written by its EXIT trap — so the pinned
local patch has an owner that goes red if it is dropped.

A collision needs a fixture that can collide. `tests/bashunit/test_dsl_parallel_isolation_probe_test.sh`
is a two-test file whose cases deliberately declare the *same* historical number —
`_bats_test_init 1` in both — then each publish their own `$BATS_TEST_TMPDIR` and assert
the two differ; the driver runs that file under `-j 2` and requires both to pass
(`tests/bashunit/scripts_test.sh:7979-7987`). It owns the key's uniqueness, which is the
property the fix established. It does not own the macOS contention profile the flake
appeared under, and no post-fix repeat of those CI runs was taken.

Not every fix in this family earns a test. The `herdr-peer-alias` EPIPE fix added none:
the only available assertion would have compared a message against the string in the
patched file, and the pre-fix behaviour was not deterministic — which is what made the
original CI failure flaky in the first place. A negative control under `trap '' PIPE`
(pre-fix reproduces, post-fix clean) was the honest evidence instead.

## Related

- `docs/solutions/design-patterns/capturing-child-output-hides-the-prompt.md` — the mirror
  class in shipped code: a foreground child the caller is actively waiting for, blocked
  because the caller captured its output while leaving it stdin. Rule 3 here is the
  test-side half; that document owns the capture-side trigger, the designed meaning of the
  resulting failure, and the terminal-gated liveness signal.
- `docs/solutions/design-patterns/idle-machine-wall-clock-bounds-are-latent-flakes.md` —
  the sibling class. That document covers bounds chosen on an idle machine; this one
  covers processes that ignore bounds entirely. A hang guard from that document is rule 4's
  third exit here.
- `docs/solutions/design-patterns/semantic-regression-tests-over-source-shape.md` —
  the suite-end orphan guard and the descriptor probes are behavioural owners in its sense:
  each was proven red on the pre-fix revision.
- `docs/solutions/architecture-patterns/child-initiated-callback-over-in-turn-supervision.md` —
  why `herdr-child` runs detached watchers at all.
- Source anchors in the current tree: `home/dot_local/lib/herdr-child-watcher.sh`,
  `home/dot_local/lib/herdr-child-supervision.sh`, `home/dot_local/bin/executable_herdr-worktree-identity`,
  `home/dot_local/bin/executable_herdr-pane-labels`, `home/dot_local/bin/executable_herdr-peer-alias`,
  `tests/run-post-apply.sh`, `tests/bashunit/test-dsl.bash`,
  `tests/bashunit/herdr_child_descriptor_probe_test.sh`,
  `tests/bashunit/herdr_pane_labels_descriptor_probe_test.sh`,
  `tests/bashunit/bashunit_late_output_probe_test.sh`,
  `tests/bashunit/test_dsl_parallel_isolation_probe_test.sh`.
- Originating closed issues, for archaeology in git history: `2026-08-24-001`,
  `2026-08-28-001`, `2026-08-29-001`, `2026-08-29-003`, `2026-08-29-005`, `2026-08-30-011`,
  `2026-09-01-001`, `2026-09-03-006`, `2026-09-03-007`,
  `2026-09-05-004` (incident 8, resolved by PR #172). The evidence they carried is
  reproduced inline above; the files themselves were removed after compounding.
