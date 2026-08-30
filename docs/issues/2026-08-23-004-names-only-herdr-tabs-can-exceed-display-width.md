---
title: "Names-only Herdr tabs can exceed display width"
short_description: "Herdr 0.8.2 dynamically clips and scrolls the tab strip, so preserving complete pane labels avoids duplicating renderer-specific width policy."
type: "follow-up"
category: "herdr"
tags: ["tab-labels","width-budget"]
date: "2026-08-23"
status: "wontfix"
priority: "low"
parent-plan: "docs/plans/2026-08-23-001-refactor-herdr-name-only-tab-labels-plan.md"
closed: "2026-08-30"
---

## Why this exists

The names-only refactor intentionally removes the Git-prefix-specific 80-column composer and preserves complete pane labels. An adversarial review found that two maximum-length agent labels can still exceed the tab row width.

## Scope

Design a generic names-only width policy that preserves useful identity for two or more panes without restoring Git or repository prefixes. Add Bats coverage for two maximum-length agent labels and for three-pane allocation.

## Open decisions

Whether tab labels should truncate each pane equally, redistribute unused width, or rely on Herdr clipping; whether the 80-column budget should remain configurable.

## Resolution

Herdr 0.8.2 owns tab-strip overflow dynamically: it sizes labels from display width, clips cells to the available viewport, and exposes scrolling for neighboring tabs. The observed UI keeps the active tab readable, so a fixed composer-side width budget would duplicate Herdr layout policy and discard pane identity prematurely.
