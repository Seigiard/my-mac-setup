---
title: The python3 version floor is stated in two places with nothing checking they agree
type: follow-up
date: 2026-08-21
status: open
parent-plan: docs/plans/2026-08-21-0337-fix-python3-declared-dependency-plan.md
---

## Why this exists

The minimum supported `python3` version is written down twice:

- `tests/helpers/common.bash` — `PYTHON3_MIN_VERSION="3.9"`, the value the test assertion
  enforces.
- `README.md`, the `## Requirements` section — the value a person setting up a machine
  reads, and the one the assertion's own failure message points them at.

Nothing checks the two agree. Bump one and the other goes stale silently: the suite would
enforce a floor the documentation does not state, or the documentation would promise a
floor the suite does not enforce. The failure message makes this worse than ordinary
drift, because it directs the reader to `README.md` for the authoritative number while
having tested a different one.

The same shape already has precedent in this repo, solved the other way. The fzf floor is
read from `palette.py`'s own `FZF_MIN_VERSION` by `tests/smoke.bats:527` specifically so
the two cannot drift — the test comment says so outright. `python3` has no equivalent
single source.

A related, smaller gap: the "python3 is absent from PATH entirely" branch of
`assert_python3_available` has no committed test. The below-floor and malformed-output
branches are covered by `a python3 below the floor, or one answering with junk, is
rejected` in `tests/palette.bats`, which stubs an interpreter on `PATH`. The absent case is
harder to stub, because emptying `PATH` far enough to hide `python3` also breaks bats
itself.

Raised by the testing reviewer during the code review of the plan named in `parent-plan`.

## Scope

1. Pick one source of truth for the floor and derive the other from it. Options:
   - keep the constant in `tests/helpers/common.bash` and add a test that greps `README.md`
     for the same number — cheap, and it fails loudly on drift;
   - or move the floor into a file both can read, mirroring how `FZF_MIN_VERSION` lives in
     `palette.py` and is read by the test.
2. Decide whether the absent-interpreter branch is worth a committed test, given the
   stubbing difficulty. It is currently proven only by an ad-hoc harness run, not by
   anything in the repo.

## Open decisions

- Is `README.md` the right home for a machine-readable constant at all? It is the file a
  human reads, which is why the assertion points there. A grep-based test couples the test
  suite to prose formatting, which is its own fragility — a heading rename or a reworded
  sentence would break it for no real reason.
- The floor is 3.9 because that is what macOS ships at `/usr/bin/python3` (3.9.6,
  measured). If macOS ever ships newer, the floor could rise — but the decision of when to
  raise it belongs with whoever checks that all four command-palette sources still compile
  under the new floor, not with a drift check.
