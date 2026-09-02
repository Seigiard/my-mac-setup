---
title: "Give onchange hash and palette fallback tests independent fixtures"
short_description: "The onchange smoke test greps template includes without rendering the template, and the palette fallback parser test copies its expected values from the mutable production commands.toml, so a broken dependency hash or a regressed fallback parser stays green."
type: "follow-up"
category: "testing-ci"
tags: ["semantic-testing","command-palette","chezmoi"]
date: "2026-09-02"
status: "open"
priority: "medium"
---

## Why this exists

Split from 2026-09-01-002. tests/bashunit/smoke_test.sh:956-968 asserts that the onchange template includes its dependencies but never proves that changing a dependency changes the rendered hash, which is the only property the onchange mechanism relies on. tests/bashunit/palette_test.sh:527-555 exercises the fallback TOML parser with expected command names and values copied from home/private_dot_config/herdr/commands.toml, so editing production configuration silently rewrites the test expectation.

## Scope

Render the onchange template before and after mutating each declared dependency and require the rendered hash to change; keep a control that proves an unrelated edit does not change it. Replace the palette fallback parser input with a minimal fixed fixture that is independent of commands.toml and covers the parser's real branches, including at least one malformed-input control. Strengthen the existing tests instead of adding new suites. Verify with tests/lib/bashunit on the two touched files, then make test-suite.

## Open decisions

None.
