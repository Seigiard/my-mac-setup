---
title: "Bats assertion checker misses a second same-line conditional"
short_description: "The checker now resumes after each handled compound conditional and rejects later bare [[...]] or ((...)) commands on the same physical line without regressing accepted shell syntax."
type: "bug"
category: "testing-ci"
tags: ["test-integrity","linting"]
date: "2026-08-28"
status: "done"
priority: "medium"
closed: "2026-08-28"
---

## Why this exists

The lint guard added for explicit Bats compound-condition assertions returns after the first recognized `[[ ... ]]` or `(( ... ))` command on each physical line. A later bare conditional on the same line is never inspected:

```bash
[[ 1 == 1 ]] || fail "first"; [[ 1 == 2 ]]
:
```

Running `python3 scripts/check_bats_assertions.py` against this fixture exits zero. The second condition can therefore reproduce the false-green assertion class while `make lint` reports success.

## Scope

- Continue scanning after each handled conditional until every top-level command segment on the physical line has been classified.
- Add a rejection fixture where an explicitly handled first conditional is followed by a bare second conditional.
- Preserve accepted quoted text, heredoc payloads, arithmetic shifts, control flow, and vendored Bats libraries.

## Open decisions

None.

## Resolution

Changed the checker to resume scanning after each compound conditional closing token, added calibrated rejection fixtures for later same-line [[...]] and ((...)) commands plus an accepted handled control, and verified make test-issues and make lint.
