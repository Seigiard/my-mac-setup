---
title: "Measurement reps leak hts.* temp dirs"
short_description: "Each bats measurement rep leaves one or more hts.* dirs under $TMPDIR (2663 total, +173 during the 2026-08-29 benchmark reps, 188 modified in 6h); same hts-teardown race family as the peer branch's 2026-08-29-001, so dedupe/renumber against it when branches merge."
type: "bug"
category: "testing-ci"
tags: ["process-cleanup","herdr-task-sync"]
date: "2026-08-29"
status: "open"
priority: "medium"
---

## Why this exists

A process-cleanup review after the 2026-08-29 test-suite optimization benchmark found 2663 `hts.*` directories under `$TMPDIR` (`/var/folders/.../T/`), up roughly 173 from the count a peer session reported before the benchmark window, with 188 modified in the last 6 hours. The growth tracks the day's bats measurement reps: `hts_teardown` in `tests/helpers/herdr_task_sync.bash` can race a surviving engine process, so some per-test `hts.*` state dirs escape deletion. The dirs are inert but accumulate without bound and poison tmp-diff tooling.

A concurrent optimization session on branch `optimize/test-suite-time` filed its own issue for the same root cause (2026-08-29-001 on that branch; this one took -003 to avoid a number collision). When the branches merge, keep one issue.

## Scope

- Reproduce the teardown race (run a herdr-task-sync-heavy bats file repeatedly and diff the `hts.*` count).
- Make `hts_teardown` reap the engine before removing the state dir, or re-attempt removal after the engine exits.
- One-time cleanup guidance for the existing pile (dirs are safe to delete when no bats run is active).

## Open decisions

None.
