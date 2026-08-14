---
title: Flaky bats test — herdr-task-sync resets the stored context on a new session id
type: bug
date: 2026-08-14
status: done
closed: 2026-08-14
---

# Flaky bats test — herdr-task-sync resets the stored context on a new session id

## Why this exists

`tests/scripts.bats:832`, the test named "herdr-task-sync resets the stored context on a new session id", fails intermittently. It failed once during a full `bats tests/scripts.bats` run on 2026-08-14, then passed in isolation (`bats tests/scripts.bats --filter "herdr-task-sync resets the stored context"`) and in three consecutive full runs afterwards. Every other test in the file passed in all four runs.

The failure is unrelated to whatever change is in flight: the test exercises the herdr task-sync adapter, which shares no code with the `se` CLI or the smithers workflows. Left alone it will eventually fail in CI, where a single red test blocks the run and the retry is not free.

**The failing assertion was not captured.** The run was filtered to `^not ok` lines, so only the test name was recorded, not which of the two assertions broke. Reproduce with the full output before fixing.

**Hypothesis, from reading the helpers.** The test synchronises on the wrong signal. `hts_wait_for_publish` (`tests/scripts.bats:731`) returns as soon as `$HTS_LOG` is merely non-empty:

```bash
hts_wait_for_publish() {
  local i
  for i in $(seq 1 60); do
    [[ -s "$HTS_LOG" ]] && return 0
    sleep 0.25
  done
  return 1
}
```

The test runs two sessions in sequence, truncating the log between them:

```bash
hts_run --agent claude --session s1 <<< 'review the cache layer please'
hts_wait_for_publish
: > "$HTS_LOG"
hts_run --agent claude --session s2 <<< 'now fix the flaky login test'
hts_wait_for_publish
```

The file's own comment at `tests/scripts.bats:740` states the problem directly: "The worker logs several herdr calls in a row, so a test that reads a later call must wait for that call and not for the first line of the log." The s1 worker is still running when the log is truncated. A late s1 write lands in the empty log, the second `hts_wait_for_publish` returns on that write, and the test reads `$HTS_WORK/pi-stdin.txt` before the s2 worker has rewritten it — so the `"Current name: (none)"` assertion checks stale s1 content.

That would make the flake timing-dependent on machine load, which matches a failure that appears once under a full suite and never in isolation.

## Scope

- `tests/scripts.bats:832` — the test itself.
- `tests/scripts.bats:731` — `hts_wait_for_publish`, the helper whose "non-empty log" signal is too weak for any test that truncates the log mid-way.
- Any other test in the file that calls `hts_wait_for_publish` after a truncation shares the same weakness; audit the call sites rather than patching this one test.

## Open decisions

- **Whether to wait on a session-specific marker** — `hts_wait_for_call` already exists at `tests/scripts.bats:742` and greps for a pattern, which is the stronger signal. Whether the s2 publish emits something uniquely greppable needs checking.
- **Whether to wait on `pi-stdin.txt` instead of the log** — the test's real precondition is that the s2 worker rewrote that file, so waiting on its mtime or content may be the honest fix.
- **Whether to drain the s1 worker before truncating** rather than strengthening the wait, which would remove the overlap instead of tolerating it.

## Resolution

The flake was made deterministic before anything was changed. Giving the first session's stubbed naming engine a three-second delay (`hts_stub_engine pi cache-review 0 3`) fails the test every time:

```
not ok 1 herdr-task-sync resets the stored context on a new session id
#   `assert_equal "$(hts_state_field "$state" first_prompt)" "now fix the flaky login test"' failed
# grep: .../state/claude-pane-1-s2.state: No such file or directory
```

That output corrects the hypothesis recorded above. The dominant cause is not a late write from the first worker landing in the truncated log — it is that **`hts_wait_for_publish` never waited for a publish**. It returned as soon as `$HTS_LOG` was non-empty, and the entry point logs `herdr pane process-info` *before* it forks the worker. So a non-empty log said only "the run started": no state file written, the naming engine not yet called, and the assertions then read whatever the previous session had left behind. The second session's state file did not exist at all.

Three changes in `tests/scripts.bats`:

1. `hts_wait_for_publish` now waits for the publish itself — the `--token task=` metadata call. This is one helper used by thirteen tests, so the weak signal is gone everywhere at once, not patched at one call site.
2. `hts_wait_for_worker_exit` waits for the tail the worker logs after publishing (`compose_tab_label` runs `pane list` and may rename the tab). The three tests that truncate the log between two sessions now drain the first worker before truncating, which removes the overlap instead of tolerating it — the third open decision. One of those three, "publishes nothing when no engine is usable (AE3)", asserts the log stays *empty*, so a straggler write would have failed it too.
3. The reset test additionally waits on `hts_wait_for_state`, the second session's own state file. Session ids are part of that path, so unlike any log line it cannot be satisfied by another session's worker.

Verified: the deterministic repro passes with the fix, then the repro delay was reverted. Three consecutive full runs of `tests/scripts.bats` are 104 ok / 0 not ok, and three further filtered runs are 34 ok. `make lint` clean.
