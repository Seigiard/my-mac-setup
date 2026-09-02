---
title: "herdr-child descriptor probe test is terminal-width dependent"
short_description: "The nested-bashunit assertion in scripts_test.sh matches the full test name in the child run's output, but bashunit truncates test names to the terminal width, so make test-ubuntu fails in a narrow pane and passes full-width."
type: "bug"
category: "testing-ci"
tags: ["flaky-test"]
date: "2026-09-02"
status: "open"
priority: "low"
---

## Why this exists

Observed once: 'herdr-child descriptor probe passes under a nested bashunit run' failed with assert_output --partial 'closes launcher descriptors' because the nested run rendered '...closes launcher desc... 258ms' in a ~half-width herdr pane; the same suite passed twice in a full-width pane. The assertion should match width-stable output (e.g. the nested run's exit status or report JSON) instead of the rendered test-name line.

## Scope

Define the work that resolves this issue.

## Open decisions

None.
