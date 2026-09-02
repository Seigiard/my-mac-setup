---
title: "scripts_test.sh hangs the Docker suite on cat holding inherited stdin"
short_description: "herdr-task-sync tests 119 and 121 leave a cat process blocked on the bashunit runner's inherited stdin pipe, so tests/bashunit/scripts_test.sh never returns after its last test passes and make test-ubuntu stalls indefinitely at 0% CPU until the container is stopped by hand."
type: "bug"
category: "testing-ci"
tags: ["bashunit","inherited-descriptors","herdr-task-sync","docker-suite"]
date: "2026-08-29"
status: "done"
priority: "high"
closed: "2026-08-29"
---

## Why this exists

`make test-ubuntu` stalled for over nine minutes on 2026-08-29 and never returned. The container stayed up at 0.00% CPU with the log frozen after the last line `herdr-task-sync coordinator resolves eight pane locations concurrently within one deadline` passed in 32.96s.

The process tree inside the container showed the cause:

```
7475  bash tests/lib/bashunit -j 8 --report-json ... tests/bashunit/scripts_test.sh
47951 └─ bash (same runner)
48750    └─ cat            S  anon_pipe_read
56224 └─ bash (same runner)
56744    └─ cat            S  anon_pipe_read
```

Both `cat` processes hold the same inherited descriptor set:

```
0 -> pipe:[99081821]      # the runner's stdin, read side; nothing ever closes the write end
1 -> /tmp/hts.XXXXXX/fail-open-stdin.XXXXXX
2 -> /tmp/bats-compat-run.XXXXXX/test-119/.bats-run-out.7475.1   (and test-121)
```

The `.bats-run-out` paths identify the owners:

- `tests/bashunit/scripts_test.sh:3395` — `test_scripts_119_herdr_task_sync_fail_open_deadline_rejects_late`, `_bats_test_init 119`
- `tests/bashunit/scripts_test.sh:3419` — `test_scripts_121_herdr_task_sync_fails_open_for_missing_tools_con`, `_bats_test_init 121`

Both tests exercise the herdr-task-sync fail-open path with a `cat` reading stdin. The test body finishes and reports green, but the `cat` survives holding the runner's inherited stdin, so the runner waits on EOF that never arrives. This is the classic inherited-descriptor hang: output looks complete, the PID is alive, and no timeout fires.

Impact: `make test-ubuntu` is the only target that applies the checkout before asserting, so a change to any managed file under `home/` cannot be proven while this hang is reachable. A CI ubuntu job hitting the same path burns its full timeout instead of failing fast.

## Scope

1. Close or redirect stdin for the `cat` invocations in tests 119 and 121 of `tests/bashunit/scripts_test.sh` so no descendant inherits the runner's stdin pipe.
2. Confirm the fix by running `tests/lib/bashunit -j 8 tests/bashunit/scripts_test.sh` and checking that no `cat` in `anon_pipe_read` survives the run.
3. Decide whether the two existing descriptor probes (`tests/bashunit/herdr_child_descriptor_probe_test.sh`, `tests/bashunit/herdr_task_sync_descriptor_probe_test.sh`) should be extended to cover the fail-open paths these two tests exercise, so the same leak fails loudly instead of hanging.
4. Re-run `make test-ubuntu` to completion.

## Open decisions

- Whether a suite-level guard belongs here as well: a runner that refuses to wait on an inherited stdin pipe would turn this class of hang into a fast failure for every future test, not just these two.

## Resolution

Redirected stdin from /dev/null for the three fail-open guard invocations that expect no payload. Verified both affected tests under an intentionally open stdin pipe, the 258-test scripts suite with no surviving cat in anon_pipe, and make test-ubuntu to completion with exit status 0.
