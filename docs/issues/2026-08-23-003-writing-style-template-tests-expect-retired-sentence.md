---
title: "Writing-style template tests expect retired sentence"
short_description: "make test-ubuntu fails three templates.bats assertions because origin/main expects the retired sentence while the managed writing-style source now uses the actionable style contract."
type: "bug"
category: "testing-ci"
tags: ["writing-style","test-regression","ubuntu"]
date: "2026-08-23"
status: "open"
priority: "high"
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
