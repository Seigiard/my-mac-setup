---
title: "claude.ts has no test for its own failed-import fail-open path"
short_description: "Resolved: a bashunit case now drives the shim against a copied core whose index.ts throws and pins exit 0 with empty output, with an intact-copy control proving the input is genuinely known-bad; the record's temporary-lib-directory approach was not available because claude.ts imports ./index.ts relative to itself, so the test runs it as a subprocess the way Claude Code does."
type: "follow-up"
category: "testing-ci"
tags: ["agent-hooks","fail-open","coverage-gap"]
date: "2026-09-06"
status: "done"
priority: "medium"
closed: "2026-09-06"
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

## Resolution

Covered by test_scripts_1021 in tests/bashunit/scripts_test.sh, beside the existing dispatch-shim case and reusing its require_bun_for_shim and temp-HOME harness. Both open decisions were answerable from the code rather than by choice. The subprocess form is the only feasible one: claude.ts imports ./index.ts relative to itself with no core-path indirection, so the record's 'point it at a temporary lib directory' works for the sibling adapters but not here; running it as a subprocess also covers the exit status, which is how Claude Code invokes it. No second missing-dispatch-export fixture: destructuring a missing export yields undefined rather than throwing, landing on the already-covered branch. The case pairs the degraded assertion with an intact-copy control that must reach a deny, so a fixture that never ran claude.ts cannot masquerade as a fail-open. Non-vacuity proved by mutation and independently re-checked: removing the try/catch turns the fail-open assertion red with status 1 and a stderr stack trace - exactly the failure mode the oracle names - while both control assertions stay green; claude.ts was restored byte-identical. Verified: 33 neighbouring tests pass, make lint clean. No source change was needed.
