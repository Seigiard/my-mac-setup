---
title: "Prove CI event policy and post-apply failure propagation independently"
short_description: "tests/test_ci_workflow.py derives its expected cache events from the workflow expression it checks, and the post-apply and Docker contract tests copy the runner's suite inventory while accepting a command whose failure is suppressed, so a wrong event set or a swallowed nonzero status stays green."
type: "follow-up"
category: "testing-ci"
tags: ["semantic-testing","ci","source-ownership"]
date: "2026-09-02"
status: "open"
priority: "medium"
---

## Why this exists

Split from 2026-09-01-002. Two confirmed dependent oracles share one boundary: what CI and the post-apply runner must actually do when inputs change or a suite fails. tests/test_ci_workflow.py:65-100 reads the workflow expression under test and rebuilds the expected event list from it, so any event added or dropped in the workflow is mirrored into the expectation. tests/test_post_apply_suite_contract.py:17-58 counts command text and copies the runner's own suite inventory instead of discovering eligible suites independently. tests/test_docker_contract.py:70-94 accepts a matching command even when its failure is suppressed, so a suite whose nonzero status never propagates still passes.

## Scope

Pin the CI event policy independently of the workflow file, then compare the workflow conditions against the explicit minimal and full event sets. Discover post-apply consumers and eligible suites through an independent rule, execute a failing wrapper through each gate, and require the nonzero status to propagate to the caller. Keep externally consumed command and transport literals and document why each stays. Do not add a parallel suite: strengthen the existing tests. Verify with the narrow python suites, then make test-suite.

## Open decisions

Whether post-apply suite eligibility should be derived from file metadata, from a canonical manifest consumed by the runner, or from another independent rule.
