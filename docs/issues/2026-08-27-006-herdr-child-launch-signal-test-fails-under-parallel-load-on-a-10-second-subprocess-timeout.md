---
title: "herdr-child launch signal test fails under parallel load on a 10 second subprocess timeout"
short_description: "The test 'herdr-child catchable launch signals preserve ownership after prompt submission' times out and fails when the suite runs in parallel, and passes when run alone."
type: "bug"
category: "testing-ci"
tags: ["flaky-test"]
date: "2026-08-27"
status: "open"
priority: "medium"
---

## Why this exists

The test drives executable_herdr-child through a Python subprocess call with a hard 10 second timeout. Under the parallel suite, and on the GitHub macOS runner, the launcher does not finish inside that window and the call raises TimeoutExpired, which the test reports as 'launcher did not handle the catchable signal'. The failure is wall-clock sensitive rather than behavioural: the same test passes in isolation, and it failed on the macOS CI job for a branch that changes no herdr-child code. A test that fails on machine load rather than on a defect trains everyone to ignore a red suite.

This is not confined to one branch: the macOS job on `main` fails the same test, at run 33091774184 for commit abbac9a0 and in every one of the five preceding runs. `main` has been red continuously, on this test plus one other that is fixed separately. Because the failure predates any branch under review, it cannot be used as a merge signal for one, and nobody can currently tell a real macOS regression from this noise.

## Scope

Determine whether the 10 second bound is measuring anything intentional. Either raise it to a value with headroom under parallel load and say in a comment what the bound is protecting against, or replace the fixed timeout with a wait on the observable the test actually cares about. Verify by running the full suite in parallel several times. Out of scope: any change to herdr-child behaviour.

## Open decisions

None.
