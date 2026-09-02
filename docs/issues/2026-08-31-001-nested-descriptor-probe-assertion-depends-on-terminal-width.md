---
title: "Nested descriptor probe assertion depends on terminal width"
short_description: "make test-ubuntu fails in a narrow TTY because bashunit abbreviates the nested descriptor-probe test name while scripts_test.sh requires its full display text."
type: "bug"
category: "testing-ci"
tags: ["bashunit","regression-test","terminal-width"]
date: "2026-08-31"
status: "open"
priority: "medium"
---

## Why this exists

A full make test-ubuntu run from a narrow Herdr sibling pane reached scripts test 258 and passed the nested descriptor probe itself, but the parent assertion failed because bashunit rendered 'herdr-child detached watcher closes launcher desc...' instead of the full test name. The gate therefore reports a false failure based on terminal presentation rather than the nested test verdict.

## Scope

Make scripts test 258 verify the nested probe's semantic success without depending on width-truncated display text. Calibrate the replacement against a failing nested probe and verify both narrow-TTY and non-TTY execution.

## Open decisions

Choose whether the parent should consume a machine-readable report, assert only status plus a stable untruncated marker, or force deterministic nested output width.
