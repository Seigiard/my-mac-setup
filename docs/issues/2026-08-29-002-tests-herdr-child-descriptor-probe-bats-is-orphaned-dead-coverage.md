---
title: "tests/herdr_child_descriptor_probe.bats is orphaned dead coverage"
short_description: "The probe file is not referenced by tests/run-post-apply.sh, any make target, or CI; its scenarios never run. Found during the bashunit migration coverage review."
type: "chore"
category: "testing-ci"
tags: ["bashunit-experiment"]
date: "2026-08-29"
status: "done"
priority: "low"
closed: "2026-08-29"
---

## Why this exists

Dead test files erode trust in what the suite actually covers and confuse coverage inventories.

## Scope

Decide: wire it into a runner or delete it. tests/herdr_child_descriptor_probe.bats only.

## Open decisions

None.

## Resolution

Probe converted to tests/bashunit/herdr_child_descriptor_probe_test.sh and wired into the nested-runner scenarios during the native bashunit migration; it is no longer orphaned.
