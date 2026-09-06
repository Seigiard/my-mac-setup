---
title: "Research simplifying herdr-child lifecycle"
short_description: "After module extraction and preliminary serializer consolidation, the herdr-child lifecycle still spans 2,701 physical lines and 79 function definitions (measured 2026-09-05, up from 2,507/72 at filing); map its state machines before attempting behavioral simplification."
type: "follow-up"
category: "herdr"
tags: ["herdr-child","maintainability","research"]
date: "2026-08-30"
status: "done"
priority: "medium"
parent-plan: "docs/plans/2026-08-30-001-refactor-herdr-child-lifecycle-modules-plan.md"
closed: "2026-09-05"
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

## Resolution

Research delivered as docs/plans/2026-09-05-herdr-child-lifecycle-simplification-research.md (1,187 lines), covering the state machine map for launch, watcher, callback, continuation, delivery and reap; measurements; removable states and mergeable helpers; the Bash versus runtime-boundary comparison; a five-stage recommendation; and an honesty ledger separating measured from inferred from unchecked. The scope's precondition was met first: the liveness, abandoned-callback and pane-retry defects (2026-08-30-005, 2026-08-30-007, 2026-08-30-009) were all resolved before current race behaviour was treated as a contract. Both open decisions are answered. Meaningful behaviour-preserving simplification is not possible: the ceiling is roughly 2 percent of 2,778 lines, about 4 percent including a parser consolidation not worth scheduling alone, because the bulk maps one-to-one onto observable contract behaviour (87 semantic tests, 36 herdr invocation sites, 25 run-directory artifacts, 13 wait policies, 13 numeric statuses, 15 failure reasons). Bash remains the lowest-risk owner of the state transitions and the Bash/Python boundary is already correctly drawn, with the four operations Bash 3.2 cannot do already in Python at 156 lines; no new runtime dependency is justified, and the one change that would genuinely shrink the engine is an upstream herdr conditional-metadata-write API, recorded as a request rather than reimplemented locally. Independently spot-checked against the tree on macOS: json_has_name has no call site outside its own definition (the only unreachable function), the engine contains exactly 28 python3 -c blocks and 24 sleep sites, and it invokes jq zero times. Implementation stays out of scope and is not tracked as follow-up work, because the measured ceiling does not justify scheduling it without a user decision. make lint (exit 0) and make test-issues (58 tests OK) pass; the change is documentation only.
