---
title: "Names-only Herdr tabs can exceed display width"
short_description: "Two valid 43-column agent pane labels plus the separator produce an 89-column tab label, so an 80-column Herdr tab row can clip one identity."
type: "follow-up"
category: "herdr"
tags: ["tab-labels","width-budget"]
date: "2026-08-23"
status: "open"
priority: "low"
parent-plan: "docs/plans/2026-08-23-001-refactor-herdr-name-only-tab-labels-plan.md"
---

## Why this exists

The names-only refactor intentionally removes the Git-prefix-specific 80-column composer and preserves complete pane labels. An adversarial review found that two maximum-length agent labels can still exceed the tab row width.

## Scope

Design a generic names-only width policy that preserves useful identity for two or more panes without restoring Git or repository prefixes. Add Bats coverage for two maximum-length agent labels and for three-pane allocation.

## Open decisions

Whether tab labels should truncate each pane equally, redistribute unused width, or rely on Herdr clipping; whether the 80-column budget should remain configurable.
