---
title: "CI and Docker contract tests restate the config they guard"
short_description: "Four of six tests in test_ci_workflow.py and test_docker_contract.py assert verbatim copies of test-dotfiles.yml and docker-compose.yml lines, so an equivalent rewrite reddens them while an uncovered trigger or a dropped env marker passes; neither file asserts the derived invariants that would catch those."
type: "bug"
category: "testing-ci"
tags: ["tautological-tests","test-quality","ci"]
date: "2026-08-29"
status: "open"
priority: "medium"
---

## Why this exists

A "contract test" that restates its config is the textbook tautological test: it reddens on
a behavior-preserving rewrite and stays green through the regression it was written to
catch. Four of the six tests in these two files are that.

- `tests/test_ci_workflow.py:39-52` — the `uses: actions/cache@v4` and `path:` literals
  mirror `.github/workflows/test-dotfiles.yml` lines 79, 81, 221, 223. The two `if: ${{ … }}`
  matches are character-for-character copies of lines 78, 220, 244, 341. Rewriting a
  condition as `contains(fromJSON('["push","pull_request"]'), github.event_name)` is
  behaviorally identical and fails the test. The real invariant — that restore-triggers and
  save-triggers are disjoint and together cover every declared trigger — is never computed.
- `tests/test_ci_workflow.py:59-61` — three `assertIn` calls mirroring workflow lines
  159-161 verbatim, including the gitleaks version pin and archive filename.
- `tests/test_docker_contract.py:26-34` and `:38-57` — all asserted literals are verbatim
  lines of `Makefile:27` and `docker/docker-compose.yml`. The `assertNotRegex(test-quick)`
  guard names a service that no longer exists anywhere, so it can only fail if someone
  reintroduces that exact string.

Two assertions in this group are sound and should be kept: `assertNotIn("brew install", …)`
and the `assertLess` step-ordering check at `test_ci_workflow.py:62-70`, which is a derived
invariant over parsed positions.

Related but separate: `test_ci_workflow.py` asserts nothing about `timeout-minutes` at all,
though the workflow declares 15 / 25 / 5 across three jobs. "Every job declares a timeout"
is the derived invariant worth adding, and it interacts with the open issue
`2026-08-21-008-revisit-ci-timeout-minutes-after-minimal-install`.

## Scope

- Replace the cache trigger literals with the disjointness invariant: read the declared
  triggers from the workflow's `on:` block rather than hard-coding them, parse both steps'
  `if:` expressions, and assert the restore and save trigger sets are disjoint and their
  union equals the declared set.
- Replace the gitleaks text mirrors with the property they stand for: extract the install
  step's `run:` script and assert its download target directory is one the workflow also
  appends to `$GITHUB_PATH`.
- In `test_docker_contract.py`, keep the one testable claim — that the staging shell puts
  `scripts/issues`, `docs/issues/` and `Makefile` in the container worktree — and test it by
  executing the extracted staging commands under a temp root. Convert the env-var checks to
  a derived invariant computed over all services rather than two named ones: every service
  running a real apply sets `MMS_DISPOSABLE_HOME` and `HOMEBREW_BUNDLE_NO_UPGRADE`.
- Add a `timeout-minutes` presence invariant over every job.

Verify with `python3 -m pytest tests/test_ci_workflow.py tests/test_docker_contract.py` or
the canonical make target that covers them.

## Open decisions

Whether the `timeout-minutes` invariant belongs here or in
`2026-08-21-008-revisit-ci-timeout-minutes-after-minimal-install`. That issue owns the
ceiling values; this one owns the assertion shape. Adding a presence-only check here does
not preempt the value decision there.
