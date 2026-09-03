---
title: "Sidebar deployment smoke expects retired row layout"
short_description: "assert_herdr_sidebar_deployment_contract still requires the pre-a25c20f single-row agents sidebar, so make test-ubuntu rejects both managed and deployed copies of the intentional two-row workspace/pane layout."
type: "bug"
category: "testing-ci"
tags: ["herdr","smoke-test","config-drift"]
date: "2026-09-03"
status: "done"
priority: "high"
closed: "2026-09-03"
---

## Why this exists

Describe the problem and its impact.

## Scope

Define the work that resolves this issue.

## Open decisions

None.

## Resolution

Updated both sidebar-row assertions to match the intentional two-row layout introduced by a25c20f. The managed-source smoke test passed with 17 assertions; deployed coverage remains assigned to make test-ubuntu.
