---
title: "se-code-review peers collide on a shared run_id and one returns the other's report"
short_description: "Both herdr peers derive the same ce-code-review run_id from identical inputs and share /tmp/compound-engineering-501/ce-code-review/<run_id>, so the second peer returns the first peer's artifact byte-for-byte; the 2026-09-06 agent-hooks review produced two identical reports with run_id 20260906-092108-e7c0b2f5, silently degrading a two-model review to one source while still looking like cross-model consensus."
type: "bug"
category: "se-pipeline"
tags: ["se-code-review","herdr-peers","review-coverage"]
date: "2026-09-06"
status: "open"
priority: "high"
---

## Why this exists

`se-code-review` exists to run the same review through two different models so
disagreement between them is visible. On 2026-09-06 it ran over the agent-hooks
migration and both peers returned the same file:

```
4e24f1e031202b5e8a6e66699766b59bee12f597da76c98682206294d03cdab2  claude.report
4e24f1e031202b5e8a6e66699766b59bee12f597da76c98682206294d03cdab2  opencode.report
```

Same `run_id` (`20260906-092108-e7c0b2f5`), same nine reviewers, same four
findings. The OpenCode peer performed no independent review.

The mechanism is the artifact path. `ce-code-review` writes to
`/tmp/compound-engineering-501/ce-code-review/<run_id>`, a per-user directory
keyed only by `run_id`, and `run_id` is derived from the review inputs. Two peers
launched concurrently against the same checkout, base and plan therefore compute
the same `run_id` and address the same directory; whichever arrives second finds
a complete artifact and returns it.

The failure is silent and it inverts the wrapper's purpose. Nothing errors, both
peers report `status: complete`, and the synthesis step sees perfect agreement on
every finding. Read naively that is the strongest possible signal, when in fact
coverage was halved. A reviewer trusting cross-model consensus is more misled by
this bug than by an outright peer failure, which the wrapper already detects and
reports as degraded coverage.

## Scope

Make two concurrent peers unable to share an artifact directory, and make an
identical pair of reports detectable rather than silently accepted.

Candidate directions, not yet decided:

- Scope the artifact path by peer, not only by run: include the peer's alias or
  pane id in the directory `ce-code-review` writes to.
- Have `se-code-review` compare the two reports before synthesis and treat a
  byte-identical or same-`run_id` pair as a degraded run, the way it already
  treats a malformed report.
- Give each peer a distinct `run_id` at dispatch.

The wrapper is `home/private_dot_claude/skills/se-code-review/SKILL.md`; the peer
lifecycle it delegates to is
`home/private_dot_claude/shared/herdr-peer-launch.md`. Both are managed here.
`ce-code-review` itself is upstream; if the fix belongs in its artifact-path
derivation rather than in this repository's wrapper, file it there and link it.

## Open decisions

- Does the fix belong in this repository's wrapper or upstream in
  `ce-code-review`?
- Is a same-`run_id` pair always a collision, or is there a legitimate case for
  two peers sharing one artifact?
- Should a detected collision fail the review or degrade it to single-source with
  a warning? Degrading matches the existing malformed-peer behaviour.
- `se-doc-review` and `se-simplify` share the same peer lifecycle. Do they share
  the defect?
