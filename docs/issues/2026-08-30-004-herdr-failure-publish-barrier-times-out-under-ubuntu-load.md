---
title: "Herdr failure-publish barrier times out under Ubuntu load"
short_description: "The superseded-watcher regression now reaches its failure-publication barrier after one mocked delivery failure, removing a five-second scheduler race while retry behavior remains covered separately."
type: "bug"
category: "testing-ci"
tags: ["herdr","flaky-test"]
date: "2026-08-30"
status: "done"
priority: "medium"
closed: "2026-08-30"
---

## Why this exists

The superseded-watcher regression waited for twelve mocked prompt failures before
reaching its failure-publication barrier. Its generic 500-poll wait could expire
under the process contention created by the eight-job Ubuntu suite, even though
the watcher was progressing normally. Two consecutive Ubuntu CI runs failed at
the same missing `failure-publish.ready` marker.

## Scope

Pin the regression fixture to one delivery attempt. Retry behavior remains owned
by the neighboring capped-backoff test, while this test continues to exercise the
stale-generation publication barrier directly.

## Open decisions

None.

## Resolution

Pinned the stale-publication regression fixture to one delivery attempt. Verified with 20 focused repetitions and the full Ubuntu Docker suite.
