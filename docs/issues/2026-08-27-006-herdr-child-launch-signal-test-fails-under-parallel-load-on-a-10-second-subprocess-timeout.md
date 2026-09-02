---
title: "herdr-child launch signal test fails under parallel load on a 10 second subprocess timeout"
short_description: "Parallel Bats workers inherit SIGINT=SIG_IGN into the launch subprocess while callback coverage reads waiting-label before failure publication completes; the tests must normalize signal disposition and wait on failed.state."
type: "bug"
category: "testing-ci"
tags: ["flaky-test"]
date: "2026-08-27"
status: "done"
priority: "medium"
closed: "2026-08-28"
---

## Why this exists

The test drives executable_herdr-child through a Python subprocess call with a hard 10 second timeout. Under the parallel suite, and on the GitHub macOS runner, the launcher does not finish inside that window and the call raises TimeoutExpired, which the test reports as 'launcher did not handle the catchable signal'. The failure is wall-clock sensitive rather than behavioural: the same test passes in isolation, and it failed on the macOS CI job for a branch that changes no herdr-child code. A test that fails on machine load rather than on a defect trains everyone to ignore a red suite.

This is not confined to one branch: the macOS job on `main` fails the same test, at run 33091774184 for commit abbac9a0 and in every one of the five preceding runs. `main` has been red continuously, on this test plus one other that is fixed separately. Because the failure predates any branch under review, it cannot be used as a merge signal for one, and nobody can currently tell a real macOS regression from this noise.

A second test in the same file fails the same way, so this is a property of the herdr-child suite rather than of one bound. In run 33120985046 the Ubuntu job failed `herdr-child callback delivery exhaustion keeps decision waiting and blocks reap` on a missing `waiting-label` file, on a commit whose only change since a passing Ubuntu run was a relocated comment and some documentation — zero code lines. That test then passed 8 times out of 8 locally, 5 alone and 3 with eight busy shells competing for CPU. Two different tests, two different failure signatures, both nondeterministic and both in `herdr-child`.

## Scope

Treat the whole herdr-child suite, not just the launch-signal test, as the unit of work: at minimum both `herdr-child catchable launch signals preserve ownership after prompt submission` and `herdr-child callback delivery exhaustion keeps decision waiting and blocks reap`. Look for the shared cause first — these tests synchronise on wall-clock sleeps and on files appearing, and a slow or contended runner breaks both. Determine whether the 10 second bound is measuring anything intentional. Either raise it to a value with headroom under parallel load and say in a comment what the bound is protecting against, or replace the fixed timeout with a wait on the observable the test actually cares about. Verify by running the full suite in parallel several times. Out of scope: any change to herdr-child behaviour.

## Open decisions

None.

## Resolution

Normalized each tested signal disposition before spawning Bash so parallel Bats workers exercise the launcher traps, turned the post-barrier timeout into a 30-second cleanup hang guard, and waited for failed.state before asserting the preserved waiting label. Verified both scenarios with repeated --jobs 8 runs, three complete 254-test parallel runs, make test-suite, make lint, and make test-issues.
