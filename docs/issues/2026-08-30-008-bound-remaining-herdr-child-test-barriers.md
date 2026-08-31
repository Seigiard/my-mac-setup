---
title: "Bound remaining herdr-child test barriers"
short_description: "HERDR_CHILD_TEST_TAB_CREATED_BARRIER, HERDR_CHILD_TEST_LAUNCH_POST_ARM_BARRIER, and HERDR_CHILD_TEST_CALLBACK_RECEIPT_BARRIER still poll without an owner or time bound, so a killed harness can strand test processes despite the earlier orphan-watcher fix."
type: "bug"
category: "testing-ci"
tags: ["herdr","test-isolation","process-cleanup"]
date: "2026-08-30"
status: "open"
priority: "medium"
---

## Why this exists

The earlier watcher-orphan fix bounded arm, release, and failure-publication
holds, but three harness-only waits still poll forever when their release file
is never written:

- `HERDR_CHILD_TEST_TAB_CREATED_BARRIER` in the launch path.
- `HERDR_CHILD_TEST_LAUNCH_POST_ARM_BARRIER` in the launch path.
- `HERDR_CHILD_TEST_CALLBACK_RECEIPT_BARRIER` in the continuation path.

A killed or failed harness can therefore strand the launcher or callback
process and keep a test runner's descriptors open.

## Scope

- Apply one shared owner-aware or elapsed-time bound to all three waits.
- Preserve their deterministic race boundaries and test-only status.
- Add calibrated regression coverage that omits each release signal and proves
  the process exits within the bound.

## Open decisions

- Whether launcher-side barriers should fail the launch or perform the same
  cleanup path as an interrupted launcher after their bound expires.
