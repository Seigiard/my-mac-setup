---
title: "Superseded watcher can restore stale failure metadata between generation check and publish"
short_description: "Per-pane serialization now keeps generation validation, monotonic sequence allocation, and metadata publication in one critical section, preventing a superseded watcher from restoring stale failure state after takeover."
type: "bug"
category: "herdr"
tags: ["concurrency"]
date: "2026-08-30"
status: "done"
priority: "medium"
closed: "2026-08-30"
---

## Why this exists

Found by the cross-model se-code-review of the fix for 2026-08-28-001 (vacuous assert_file_not_exists). The adversarial reviewer validated the interleaving: generation G passes watcher_generation_current, generation H publishes and clears failure metadata, then G's unconditioned report-metadata call runs and restores G's failure labels and tokens over H. The window predates that fix: the old set +e bracket had the same check-then-publish sequence; on this interleaving it also published stale metadata (on the detected mismatch it died instead).

## Scope

Make the failure-metadata publication conditional on the pane still carrying the publishing watcher's generation, e.g. an atomic expected-generation precondition on herdr pane report-metadata (likely needs herdr-side support). Add a deterministic barrier test that supersedes between validation and publication and asserts the new generation keeps cleared failure metadata (extend tests/bashunit/scripts_test.sh test 040's barrier scheme).

## Open decisions

Whether herdr grows an atomic compare-and-publish for pane metadata, or herdr-child re-validates and tolerates a benign race with a bounded self-correction.

## Resolution

Serialized every herdr-child metadata writer with a per-pane lock, revalidated watcher generation and identity inside the failure publisher's critical section, and allocated process-shared monotonic metadata sequences under the same lock. Added a deterministic takeover barrier regression test and source-sequence-aware Herdr stub. Verified with focused tests, make lint, make test-issues, the full scripts_test.sh suite, and make test-ubuntu.
