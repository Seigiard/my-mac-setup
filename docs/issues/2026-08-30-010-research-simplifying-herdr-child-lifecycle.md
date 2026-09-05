---
title: "Research simplifying herdr-child lifecycle"
short_description: "After module extraction and preliminary serializer consolidation, the herdr-child lifecycle still spans 2,701 physical lines and 79 function definitions (measured 2026-09-05, up from 2,507/72 at filing); map its state machines before attempting behavioral simplification."
type: "follow-up"
category: "herdr"
tags: ["herdr-child","maintainability","research"]
date: "2026-08-30"
status: "open"
priority: "medium"
parent-plan: "docs/plans/2026-08-30-001-refactor-herdr-child-lifecycle-modules-plan.md"
---

## Why this exists

The lifecycle engine grew from 405 lines when detached supervision added
generation tracking, watcher delivery, callbacks, retries, continuation, and
reap recovery, followed by several race-condition fixes. The extracted source
now spans 2,701 physical lines across the entrypoint and six modules
(measured 2026-09-05; 2,507 at filing, grown by `a59c3b4` and `9f1b017`).

The current source defines 79 functions, including four nested definitions
(`herdr-child-launch.sh:166,194,480` and `herdr-child-continuation.sh:97`).
The module follow-up already centralized watcher-state polling and
`launch.state` serialization, reducing ten physical lines, but it did not
simplify the state machines, retry policies, embedded Python predicates, or
recovery branches. Reachability does not prove that those behaviors form the
smallest design that preserves the user contract.

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
- Resolve the known liveness, abandoned-callback, and pane-retry defects before
  treating current race behavior as a contract to preserve.

Implementation is out of scope until the research identifies a smaller design
that preserves or explicitly revises the current lifecycle contract.

## Open decisions

- Whether meaningful simplification is possible without changing detached
  supervision behavior.
- Whether Bash remains the lowest-risk owner for every state transition after
  the module boundaries are established.
