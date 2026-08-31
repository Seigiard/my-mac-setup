---
title: "Research simplifying herdr-child lifecycle"
short_description: "All 71 extracted functions are statically reachable, but detached supervision and subsequent race hardening expanded the lifecycle engine from 405 to 2,468 lines; measure which states, helpers, and embedded predicates can be consolidated without weakening recovery semantics."
type: "follow-up"
category: "herdr"
tags: ["herdr-child","maintainability","research"]
date: "2026-08-30"
status: "open"
priority: "medium"
parent-plan: "docs/plans/2026-08-30-001-refactor-herdr-child-lifecycle-modules-plan.md"
---

## Why this exists

The lifecycle engine grew from 405 to 2,468 lines when detached supervision
added generation tracking, watcher delivery, callbacks, retries, continuation,
and reap recovery, followed by several race-condition fixes. The module
extraction makes those responsibilities reviewable, but deliberately preserves
their total implementation size and behavior.

A static call-graph audit found all 71 functions reachable, including 70 from
production command roots and one from test-only barrier paths. Reachability does
not prove that every state, helper, embedded Python predicate, or recovery branch
is the smallest design that preserves the user contract.

## Scope

- Map the launch, watcher, callback, continuation, delivery, and reap state
  machines, including their shared states and ownership invariants.
- Measure repeated metadata parsing, transition handling, retry policy,
  cleanup, and embedded Python predicates instead of inferring duplication from
  source shape.
- Identify removable states or mergeable helpers and name the semantic tests
  that protect each proposed simplification.
- Compare keeping the implementation in Bash with moving only deterministic
  state transitions or JSON predicates behind one existing runtime dependency.
- Produce a staged recommendation with expected line-count reduction, behavior
  impact, migration risk, and red/green verification strategy.

Implementation is out of scope until the research identifies a smaller design
that preserves or explicitly revises the current lifecycle contract.

## Open decisions

- Whether meaningful simplification is possible without changing detached
  supervision behavior.
- Whether Bash remains the lowest-risk owner for every state transition after
  the module boundaries are established.
