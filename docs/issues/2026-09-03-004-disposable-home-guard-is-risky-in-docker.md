---
title: "Disposable-home guard is risky in Docker"
short_description: "test_idempotent_010 reaches its Docker success path without a bashunit assertion, so --fail-on-risky makes make test-ubuntu fail despite the required MMS_DISPOSABLE_HOME=1 marker being present."
type: "bug"
category: "testing-ci"
tags: ["docker","bashunit","disposable-home"]
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

Added an explicit assert_equal for MMS_DISPOSABLE_HOME=1 on the Docker success path. The next make test-ubuntu run reported the guard as passed rather than risky; its remaining failure was an unrelated stale sidebar expectation.
