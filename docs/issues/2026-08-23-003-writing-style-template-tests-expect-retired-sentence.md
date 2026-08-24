---
title: "Writing-style template tests expect retired sentence"
short_description: "PR #71 replaced all stale writing-style assertions with the current shared contract; the template gate passes, while full Ubuntu completion remains blocked later by tracked issue 2026-08-24-002."
type: "bug"
category: "testing-ci"
tags: ["writing-style","test-regression","ubuntu"]
date: "2026-08-23"
status: "done"
priority: "high"
closed: "2026-08-24"
---

## Why this exists

`make test-ubuntu` fails tests 23-25 in `tests/templates.bats` before chezmoi apply. Each test expects `Answer first: the conclusion is line one.`, but the managed Claude output style, Pi instructions, and shared agent instructions now render the newer actionable writing-style contract.

`git diff origin/main -- tests/templates.bats home/private_dot_claude/output-styles home/private_dot_config/agents home/private_dot_pi` is empty, so this is an `origin/main` baseline failure rather than a branch regression. The failure prevents the full disposable Ubuntu verification gate from reaching apply and post-apply tests.

## Scope

- Replace the three retired sentence assertions in `tests/templates.bats` with stable assertions from the current writing-style contract.
- Keep separate assertions for the Claude output style, Pi `APPEND_SYSTEM.md`, and shared `agents/writing-style.md` render paths.
- Run `make test-ubuntu` to prove the pre-apply gate and the remaining disposable suite complete.

## Open decisions

- Decide which current sentence or structural marker is stable enough to serve as the shared render assertion.

## Resolution

Already resolved by PR #71, which replaced the three stale template assertions and three matching smoke assertions with the current shared writing-style contract. make test-templates passed all 37 template cases. make test-ubuntu passed the writing-style template, apply, and post-apply checks, then failed later in Smithers at the separate blocker tracked by 2026-08-24-002.
