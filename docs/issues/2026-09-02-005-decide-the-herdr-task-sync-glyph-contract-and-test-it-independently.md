---
title: "Decide the Herdr task-sync glyph contract and test it independently"
short_description: "tests/helpers/herdr_task_sync.bash extracts the expected user-facing glyphs from the implementation that emits them, so the glyph assertions cannot fail when the rendered status vocabulary changes."
type: "follow-up"
category: "testing-ci"
tags: ["semantic-testing","herdr","source-ownership"]
date: "2026-09-02"
status: "done"
priority: "medium"
closed: "2026-09-02"
---

## Why this exists

Split from 2026-09-01-002. tests/helpers/herdr_task_sync.bash:12-34 derives the expected glyph set from the implementation under test, so every glyph test compares the implementation against itself. Whether that is fixable by pinning literals depends on whether the glyph set is a user-facing contract or replaceable presentation.

## Scope

Establish which of the two the glyph set is, then act on it. If exact glyphs are user-facing policy, pin them in the test as independent literals with a short comment naming the consumer that depends on them. Otherwise assert semantic token roles (a status has a distinct, stable marker per state) without copying implementation literals. Default to the semantic-role reading unless an external consumer of the exact glyphs is found. Strengthen the existing helper and its callers instead of adding a new suite. Verify with the herdr task-sync bashunit files, then make test-suite.

## Open decisions

Settled: Herdr's exact `$git_ref` glyph set (`ICON_BRANCH`, `ICON_WORKTREE`, `ICON_COMMIT`, `ICON_FOLDER`, `ICON_STALE` in `home/dot_local/bin/executable_herdr-task-sync`) is stable user-facing policy, not replaceable presentation. Evidence: the glyphs render directly into the pane label a user reads (`home/dot_local/bin/executable_herdr-task-sync:1186-1195`); the engine's own "Environment overrides" comment block (lines 21-23) lists `HERDR_TASK_SYNC_PI_MODEL`, `HERDR_TASK_SYNC_CLAUDE_MODEL`, `HERDR_TASK_SYNC_TIMEOUT`, and `HERDR_TASK_SYNC_STATE_DIR` as the only overridable inputs — no `ICON_*` override exists, unlike `LABEL_SEPARATOR`, which does have one (`HERDR_TASK_SYNC_SEPARATOR`); and a repo-wide search of `home/private_dot_config/herdr/` found no config key, theme, or plugin that reads or sets these glyphs. `tests/helpers/herdr_task_sync.bash` now pins `HTS_ICON_*` as independent literals, the same treatment already given to `HTS_GIT_BEHIND`/`HTS_GIT_AHEAD`, and `hts_icon()` (the extraction that derived them from the engine) has been removed.

## Resolution

Merged in PR #140. The exact glyph set was confirmed to be user-facing policy: the engine offers an override for the label separator but none for ICON_*, and no herdr config key reads them. The test helper stopped sed-extracting glyphs from the engine it guards and pins them as independent literals, matching the treatment the git status symbols already had. Changing one codepoint in the engine now fails 19 assertions that previously could not fail. The solutions doc that documented the opposite pattern was updated with the discriminator instead of being left to mislead the next reader.
