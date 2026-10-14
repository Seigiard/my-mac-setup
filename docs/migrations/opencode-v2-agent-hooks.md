---
title: OpenCode 2 agent-hooks boundary
---

# OpenCode 2 Agent-Hooks Boundary

The isolated V2 probe that established this boundary left the then-normal V1
pin unchanged. One default definition, `agent-hooks`, provides `server()` for
the V1 loader and `setup()` for the V2 loader. Both entrypoints call the same
adapter. V1 selects `server()` and V2 selects `setup()`, so either loader
registers exactly one Hooks handler.

OpenCode 2.0.28 was exercised through standalone root sessions with a local,
deterministic OpenAI-compatible provider. The adapter observed and dispatched
native `shell`, `write`, and `edit` calls, plus Code Mode's nested
`fff_grep` call. V2 supplies arguments in `event.input`; native write and edit
use `path`, and edit replacement text is `newString`. The effective FFF route
was `fff_grep` with `query` as its required policy input.

The verified scope is the pinned standalone V2 server and its root sessions.
It does not establish OpenCode subagent enforcement. Import, normalization,
and dispatch failures fail open; an explicit core block is rethrown so OpenCode
rejects the tool call. A successful V2 setup writes the same resident
loaded-core marker as V1 for selfcheck. Repeated setup and adapter
re-evaluation retain the identity of a cached enforcing core: after the core on
disk changes, selfcheck reports the resident session as stale rather than
claiming it loaded the new deployment. An unchanged deployment remains current.
This adapter-lifetime behavior is covered locally; runtime source hot reload in
the V2 server was attempted but not observed.
