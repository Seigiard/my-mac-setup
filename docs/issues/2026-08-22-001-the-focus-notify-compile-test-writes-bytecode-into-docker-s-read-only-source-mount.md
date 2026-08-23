---
title: "The focus-notify compile test writes bytecode into Docker's read-only source mount"
short_description: "make test-ubuntu reaches case 32, where python3 -m py_compile tries to create __pycache__ under the read-only /home/testuser/dotfiles mount and exits with Errno 30."
type: "bug"
category: "testing-ci"
tags: ["testing-ci","docker"]
date: "2026-08-22"
status: "done"
priority: "high"
closed: "2026-08-23"
---

## Why this exists

`make test-ubuntu` mounts `home/` at `/home/testuser/dotfiles:ro`. The smoke
test at `tests/smoke.bats:560` runs:

```sh
python3 -m py_compile "$FOCUS_NOTIFY_DIR/notify.py"
```

Python tries to create `__pycache__` beside `notify.py`, so the test fails with:

```
[Errno 30] Read-only file system: '/home/testuser/dotfiles/private_dot_config/herdr/plugins/herdr-focus-notify/__pycache__'
```

The failure is independent of the Pi updater import fixed in
`docs/issues/2026-08-21-011-pi-brew-test-unresolvable-path-in-docker.md`. The
full Docker suite reaches and passes that focused test at case 72, but this
earlier case 32 keeps the suite exit status red.

## Scope

- Make the compile assertion write bytecode under `BATS_TEST_TMPDIR`, or disable
  bytecode output while preserving syntax validation.
- Verify the focused smoke test inside Docker.
- Run `make test-ubuntu` to confirm that the full suite passes this case.

## Open decisions

- Choose whether `py_compile` should use its explicit output-path API or whether
  the test should use a syntax check that does not write beside the source.

## Resolution

Updated tests/smoke.bats so the focus-notify py_compile assertion writes bytecode under BATS_TEST_TMPDIR via PYTHONPYCACHEPREFIX. Verified the focused Docker smoke test and make test-ubuntu.
