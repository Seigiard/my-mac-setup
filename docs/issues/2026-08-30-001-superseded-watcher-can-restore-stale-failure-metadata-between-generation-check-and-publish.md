---
title: "Superseded watcher can restore stale failure metadata between generation check and publish"
short_description: "watcher_publish_failed validates the generation with watcher_generation_current and then calls herdr pane report-metadata as a separate step. A continuation that takes over the pane between the check and the publish gets its fresh state labels cleared and the old generation's failure tokens restored. Pre-existing TOCTOU, unchanged by the 2026-08-30 supersede-cleanup fix, which only made the detected-supersede path clean up its run directory."
type: "bug"
category: "herdr"
tags: ["concurrency"]
date: "2026-08-30"
status: "open"
priority: "medium"
---

## Why this exists

Found by the cross-model se-code-review of the fix for 2026-08-28-001 (vacuous assert_file_not_exists). The adversarial reviewer validated the interleaving: generation G passes watcher_generation_current, generation H publishes and clears failure metadata, then G's unconditioned report-metadata call runs and restores G's failure labels and tokens over H. The window predates that fix: the old set +e bracket had the same check-then-publish sequence; on this interleaving it also published stale metadata (on the detected mismatch it died instead).

## Scope

Make the failure-metadata publication conditional on the pane still carrying the publishing watcher's generation, e.g. an atomic expected-generation precondition on herdr pane report-metadata (likely needs herdr-side support). Add a deterministic barrier test that supersedes between validation and publication and asserts the new generation keeps cleared failure metadata (extend tests/bashunit/scripts_test.sh test 040's barrier scheme).

## Open decisions

Whether herdr grows an atomic compare-and-publish for pane metadata, or herdr-child re-validates and tolerates a benign race with a bounded self-correction.
