---
title: "Decide the Herdr task-sync glyph contract and test it independently"
short_description: "tests/helpers/herdr_task_sync.bash extracts the expected user-facing glyphs from the implementation that emits them, so the glyph assertions cannot fail when the rendered status vocabulary changes."
type: "follow-up"
category: "testing-ci"
tags: ["semantic-testing","herdr","source-ownership"]
date: "2026-09-02"
status: "open"
priority: "medium"
---

## Why this exists

Split from 2026-09-01-002. tests/helpers/herdr_task_sync.bash:12-34 derives the expected glyph set from the implementation under test, so every glyph test compares the implementation against itself. Whether that is fixable by pinning literals depends on whether the glyph set is a user-facing contract or replaceable presentation.

## Scope

Establish which of the two the glyph set is, then act on it. If exact glyphs are user-facing policy, pin them in the test as independent literals with a short comment naming the consumer that depends on them. Otherwise assert semantic token roles (a status has a distinct, stable marker per state) without copying implementation literals. Default to the semantic-role reading unless an external consumer of the exact glyphs is found. Strengthen the existing helper and its callers instead of adding a new suite. Verify with the herdr task-sync bashunit files, then make test-suite.

## Open decisions

Whether Herdr's exact glyph set is stable user-facing policy or replaceable presentation; record the answer in the issue before closing it.
