---
title: No test observes which TOML parser the command palette actually used
type: follow-up
date: 2026-08-21
status: open
---

## Why this exists

The herdr command palette parses TOML through `tomllib` when the interpreter is
>= 3.11 and through its own fallback parser otherwise
(`home/private_dot_config/herdr/plugins/command-palette/palette.py:156-171`).
The only test that touches this split forces the fallback by monkeypatching
`builtins.__import__` — no test reports which branch a real run took.

That was tolerable while the interpreter was pinned. It stopped being
tolerable when `brew "grc"` left the Brewfile
(`docs/issues/2026-08-21-010-grc-is-vestigial-and-rgrc-was-never-moved-cross-platform.md`):
removing grc removed Homebrew's `python@3.14` from the Docker image, and the
palette silently dropped to the apt interpreter (`python3` 3.12.3 on
`ubuntu:24.04`, still `tomllib`). The switch changed nothing observable. A
future base-image move to anything older than 3.11 would flip the branch to the
fallback parser with nothing reporting it — the exact class of silent change
this suite exists to catch.

## Scope

- Add a test (likely in `tests/palette.bats` or the palette's own test file)
  that runs the palette on the ambient interpreter and asserts which parser
  branch executed — e.g. via a debug/verbose flag, an importable probe, or an
  assertion that the interpreter is >= 3.11 so `tomllib` is the branch in use.
- The assertion should fail loudly when the branch flips, naming the
  interpreter version it found.

## Open decisions

- Whether to assert "tomllib is in use" (pins the current state, fails on any
  downgrade) or merely to surface the branch in test output (observable but
  never red). The first is the honest gate; the second is noise.
