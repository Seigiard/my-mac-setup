---
title: "Ubuntu Docker omits issue CLI from Smithers tests"
short_description: "Docker test services now stage the issue CLI, issue records, a worktree marker, and the Makefile so the canonical Smithers gate and post-apply issue smoke test run from the reconstructed checkout."
type: "bug"
category: "testing-ci"
tags: ["docker","smithers","test-gate"]
date: "2026-08-24"
status: "done"
priority: "medium"
closed: "2026-08-24"
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

## Resolution

Mounted and staged scripts/issues, docs/issues, and Makefile in both Docker test services, created the staged worktree marker required by the issue CLI, and replaced duplicated Bun commands with make test-smithers. Added a two-service Docker contract regression test and verified it red when the test-ubuntu CLI mount was removed and green after restoration. Verified make test-smithers with 626 passing tests, make test-issues with 41 passing tests, Compose validation, and make test-ubuntu through all 357 post-apply Bats cases.
