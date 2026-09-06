---
title: "claude.ts has no test for its own failed-import fail-open path"
short_description: "The OpenCode and Pi adapters each carry a unit test proving a core directory whose import throws registers no handler, but the Claude adapter has no equivalent at any layer; the nearest bashunit case deletes claude.ts itself, which the bash shim's file-existence check intercepts before the dynamic import ever runs, so R4's fail-open guarantee is unproven for the one client that dispatches per tool call."
type: "follow-up"
category: "testing-ci"
tags: ["agent-hooks","fail-open","coverage-gap"]
date: "2026-09-06"
status: "open"
priority: "medium"
---

## Why this exists

`home/dot_local/lib/agent-hooks/claude.ts` states the guarantee in its own
header: every failure path, including "a core that will not import", falls open
and exits 0. R4 requires it, and a regression here is expensive in a way the
other clients' is not, because the Claude adapter runs as a fresh subprocess on
every matched tool call.

The other two adapters prove it. `tests/agent-hooks-opencode-adapter.test.ts` and
`tests/agent-hooks-pi-adapter.test.ts` each carry a case pointing the adapter at
a core directory whose import throws and asserting that no handler is registered.
`claude.ts` has no equivalent at any layer.

The nearest existing coverage does not reach it. The bashunit case
`dispatch shim exits 0 silently when the deployed core file is absent` deletes
`claude.ts`, and the bash shim's own `[ -f "$core" ]` check returns before the
dynamic import is ever attempted. So the shim's guard is tested and the adapter's
is not; a `claude.ts` that threw on a broken core would pass every gate in the
repository today.

## Scope

Add one bun test for `claude.ts` mirroring the opencode and pi adapter cases:
point it at a temporary lib directory containing an `index.ts` that throws on
import, feed a known-bad canary on stdin, and assert the process exits 0 and
emits no deny.

The oracle is independent of the code under test: the expected behaviour is
stated by R4 in the plan and demonstrated by the two sibling adapter tests, both
of which predate any change this issue would make.

## Open decisions

- Does the test exercise `claude.ts` as a subprocess, matching how Claude Code
  actually invokes it, or by import, matching how the sibling suites are written?
  The subprocess form is closer to production and also covers the exit status.
- Is a broken-import fixture enough, or should the same case also cover a core
  whose module loads but whose `dispatch` export is missing?
