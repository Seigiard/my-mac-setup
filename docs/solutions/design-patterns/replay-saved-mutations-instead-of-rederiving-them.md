---
title: Replay saved mutations instead of re-deriving them
date: 2026-11-13
category: design-patterns
module: agent-platform
problem_type: design_pattern
component: development_workflow
severity: medium
resolution_type: workflow_improvement
related_components:
  - tooling
  - documentation
applies_when:
  - "A workflow proves that a test can go red by applying a temporary regression to production code"
  - "The proof is invalidated by a later production change and has to be produced again"
  - "A model-driven child produces the proof, and each repetition costs a dispatch, a report, and a verification"
symptoms:
  - "Every review round re-runs the whole mutation list through a fresh child, 10-20 minutes per round"
  - "The child re-derives mutations that an earlier child already wrote and saved"
  - "A plan row names a full-suite command, so one mutation costs a full test run"
tags:
  - tdd
  - calibration
  - mutation-testing
  - false-green
  - evidence-reuse
---

# Replay saved mutations instead of re-deriving them

## Context

The `tdd` skill calibrates a test that was only ever seen green: a child applies the smallest faithful regression to production code, runs the owner test, requires red, and restores the code. The evidence is valid until the protected code changes. A review round changes production code, so each round invalidated the evidence, and the skill answered with a fresh calibrate child that derived every mutation again.

## Problem

The expensive part of a re-calibration is not the test run. It is the child: reading the brief, re-deriving each mutation from the contract, writing the report, and the orchestrator verifying it. The mutations themselves were already derived once and saved as diffs in the run directory, but nothing read them again. A plan row that named the whole suite as its command multiplied the cost by the suite's duration.

## Solution

The first calibrate child saves each mutation as a `git apply`-able patch beside its log, and the plan row in `ticket.md` records the patch path. The orchestrator replays the patches itself and dispatches a child only for a patch that does not apply or a run that stays green, because it cannot tell a moved line from a weakened test. The procedure lives in the Replay section of `home/private_dot_agents/skills/tdd/calibration.md`.

## Why this holds in general

A saved patch encodes a regression derived from the contract, not from the code's shape. If it applies to the new code and the test goes red, the test still catches that regression on that code. Both failure forms are visible: a patch that does not apply, or a green run. Neither is silently accepted. The rule that decides staleness stays simple on purpose: any path outside the lock changed since `calibration_sha`. A narrower rule, such as "only the mutated files", misses a change elsewhere that routes the owner test away from the mutated code. Replay is cheap enough that the broad rule costs nothing.
