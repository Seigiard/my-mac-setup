---
title: "Herdr task-sync fixture accepts equal metadata sequences"
short_description: "The task-sync metadata stub applies seq equal to the current source high-water, while Herdr accepts only strictly greater sequences; tests can therefore diverge from production ordering semantics."
type: "bug"
category: "testing-ci"
tags: ["semantic-tests","herdr"]
date: "2026-08-30"
status: "done"
priority: "medium"
closed: "2026-08-30"
---

## Why this exists

Describe the problem and its impact.

## Scope

Define the work that resolves this issue.

## Open decisions

None.

## Resolution

Changed the Herdr task-sync stub to ignore metadata sequences less than or equal to the current source high-water, added an equal-sequence regression assertion, and updated the retired-token fixture to publish with a strictly newer sequence. Verified with focused bashunit tests and make test-suite.
