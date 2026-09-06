---
title: "Pi fff-grep route needs the pattern arg dialect"
short_description: "Pi's fff grep tool is verified as ffgrep (@ff-labs/pi-fff 0.10.6, default mode tools-and-ui), but it sends its query as input.pattern while the agent-hooks core's pi reader only reads input.query, so adding the identifier to the registry alone would make fff-grep-guard applicable to Pi while every real call carries an empty query and silently passes."
type: "follow-up"
category: "agent-platform"
tags: ["agent-hooks","fff","pi","tool-identifiers"]
date: "2026-09-05"
status: "open"
priority: "medium"
---

## Why this exists

U5 (Pi agent-hooks adapter) had to resolve Pi's fff tool identifier or record
evidence of absence; "unverified" is not a terminal state (plan requirement R3).

The identifier is resolved. `@ff-labs/pi-fff` 0.10.6 registers its grep tool as
`ffgrep` in its default `tools-and-ui` mode (`OVERRIDE_TOOL_NAMES` would spell it
`grep`, but that mode needs a `pi-fff.json` with `"mode": "override"`, and none
exists in this setup). Observed live in pi 0.84.4 twice: a scratch extension
logging `tool_call` recorded
`toolName="ffgrep" input={"pattern":"PROBEIDENTIFIER","path":"**","limit":20}`,
and a session asked to enumerate its tools listed `ffgrep` and `fffind`.

What is not resolved is the argument dialect. `ffgrep` carries the search text in
`input.pattern`; `readPi` in `home/dot_local/lib/agent-hooks/normalize.ts` reads
`input.query` (Claude's `mcp__fff__grep` and opencode's `fff_grep` both use
`query`). Adding `ffgrep: "fff-grep"` to Pi's registry profile without the
dialect change would be worse than the current omission: `isApplicable` would
report `fff-grep-guard` live for Pi, the selfcheck canary would pass because it
encodes its own event through `encodeEvent` (which writes `query`), and every
real `ffgrep` call would arrive with an empty query and pass the guard. That is
the silent runtime miss R3 forbids, dressed as coverage.

U5 therefore left Pi's profile without an fff entry, unchanged from U1.

## Scope

- Teach the core's pi reader that the fff query field is `pattern`, keeping the
  existing `query` read so a non-fff route is unaffected, and give `encodeEvent`
  the matching inverse so the canary and the parity test drive the real field.
- Add `ffgrep: "fff-grep"` to the pi profile in
  `home/dot_local/lib/agent-hooks/registry.ts`.
- Update the registry-derived inventories in `tests/agent-hooks-core.test.ts`
  (`applicableClients` for `fff-grep-guard`, and the selfcheck canary route
  list, which gains `fff-grep-guard@pi`).
- Extend `tests/agent-hooks-pi-adapter.test.ts` with the fff deny and its
  single-identifier control, the way the opencode suite covers `fff_grep`.
- `fff-grep-guard`'s reason text is client-neutral: it names the fff grep and
  fff multi-grep capabilities rather than any client's spelling of them, so a
  Pi deny would already read correctly if Pi ever got a live fff route. What
  stays open here is the route itself, not the wording.

## Open decisions

- Whether the mode-dependence of the identifier matters. `pi-fff` renames the
  tool to `grep` under `"mode": "override"`, and the mode can also be restored
  per session from session state. A static registry entry covers only the
  default mode; a second entry (`grep: "fff-grep"`) would collide with nothing
  today but would claim a name pi's own builtins do not use.
