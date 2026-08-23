---
title: "Update writing-style template assertions"
short_description: "Six template and smoke assertions required a sentence removed from the shared writing-style template, blocking both Docker verification targets on origin/main."
type: "bug"
category: "testing-ci"
tags: ["regression","templates"]
date: "2026-08-23"
status: "done"
priority: "medium"
closed: "2026-08-23"
---

## Why this exists

`make test-templates` and `make test-ubuntu` fail in six existing cases because
`tests/templates.bats` and `tests/smoke.bats` still require `Answer first: the
conclusion is line one.`, which no longer exists in
`home/.chezmoitemplates/writing-style.md` on `origin/main`. The stale
assertions block unrelated template changes from getting a green baseline.

## Scope

Update the source-render and deployed-file assertions for the Claude output
style, Pi `APPEND_SYSTEM`, and shared agent writing-style file to check a stable
substantive rule from the current canonical template. Keep all three adapters
covered without changing the writing-style content as part of this fix.

## Open decisions

None.

## Resolution

Updated all six shared writing-style rendering and deployment assertions to a substantive rule sentence from the current canonical template. `make test-templates` passes all 43 template tests, and `make test-ubuntu` passes all 368 post-apply tests with the expected environment-specific skips.
