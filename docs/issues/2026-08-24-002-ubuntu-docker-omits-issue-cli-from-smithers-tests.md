---
title: "Ubuntu Docker omits issue CLI from Smithers tests"
short_description: "make test-ubuntu fails the Smithers publishIssue real-CLI test because the staged Docker worktree omits scripts/issues, even though the same 626-test gate passes from the complete host checkout."
type: "bug"
category: "testing-ci"
tags: ["docker","smithers","test-gate"]
date: "2026-08-24"
status: "open"
priority: "medium"
---

## Why this exists

`make test-ubuntu` fails before post-apply Bats coverage in the Smithers test
`publishIssue > retries the real CLI idempotently by run ID`. The Docker
worktree stages only `home/`, `tests/`, and `README.md`, but the test copies
`scripts/issues` from the repository root. That path is absent in the staged
worktree, so the test fails immediately. The same 626-test Smithers gate passes
from the complete host checkout.

This blocks the canonical Ubuntu verification target for unrelated changes and
can hide whether their post-apply tests pass in the container.

## Scope

- Stage the repository issue CLI and any required root files in the Docker
  worktree used by `test-ubuntu` and `test-full`.
- Keep Docker and GitHub Actions on the canonical `make test-smithers` contract
  rather than reconstructing only part of that gate.
- Verify `make test-ubuntu` reaches and completes the post-apply Bats suite.

## Open decisions

None.
