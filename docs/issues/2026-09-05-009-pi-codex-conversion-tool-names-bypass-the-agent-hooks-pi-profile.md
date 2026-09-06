---
title: "Pi codex-conversion tool names bypass the agent-hooks pi profile"
short_description: "With the deployed default provider openai-codex, the @howaboua/pi-codex-conversion extension replaces Pi's builtin bash/edit/write with exec_command (input.cmd) and apply_patch, so every tool_call the agent-hooks pi adapter sees carries a name absent from the registry's pi profile and no policy fires in the user's actual configuration."
type: "bug"
category: "agent-platform"
tags: ["agent-hooks","pi","tool-identifiers","codex"]
date: "2026-09-05"
status: "open"
priority: "high"
---

## Why this exists

The agent-hooks registry maps Pi's tools statically as `edit`, `write`, `bash`
(`home/dot_local/lib/agent-hooks/registry.ts`), and the core's pi reader takes a
shell command from `input.command`
(`home/dot_local/lib/agent-hooks/normalize.ts`). Those are pi's builtin
spellings, and they are what the U5 adapter was verified against.

They are not what this machine's pi actually sends. `home/dot_pi/agent/modify_settings.json`
installs `npm:@howaboua/pi-codex-conversion`, and `~/.pi/agent/settings.json`
sets `defaultProvider: openai-codex`. Under that provider the conversion
extension registers its own `exec_command` and `apply_patch` tools
(`src/tools/exec/command-tool.ts`, `src/tools/apply-patch/tool.ts`) and the
builtins disappear from the model's tool surface.

Observed in pi 0.84.4 with the full deployed package set, via a scratch
extension logging every `tool_call`:

```
tool_call toolName="exec_command" inputKeys=["cmd"] input={"cmd":"printf 'HELLO\n'"}
```

A session asked to enumerate its tools answered `exec_command`, `apply_patch`,
`view_image`, `subagent`, ... with no `bash`, `edit`, or `write` anywhere.

Consequence: `normalizeEvent` finds no `toolKindFor("exec_command")`, returns
undefined, and dispatch allows. Every policy is inert on this machine's pi even
though the extension loaded, imported the core, and wrote its session marker.
The U5 suite and the live deny check both pass because they exercise the builtin
spellings — the adapter is correct; the profile does not describe the deployed
client.

This is the "no silent runtime miss" rule (R3) failing in the direction the
registry was supposed to prevent: the registry says pi enforces three policies,
and pi enforces none.

## Scope

- Add the codex-conversion spellings to the pi profile: `exec_command` -> `bash`
  and `apply_patch` -> `edit`/`write` as the payload allows. The profile's
  tool-name map is many-to-one already (Claude maps both `Edit` and `MultiEdit`
  to `edit`), so both spellings can coexist and the profile stays correct
  whichever provider is selected.
- Teach the core's pi reader `exec_command`'s `input.cmd` alongside
  `input.command`, and decide what `apply_patch` offers as content: its payload
  is a unified patch envelope, not a `path` plus `edits[].newText`, so
  test-oracle-guard needs either a patch parser or an explicit
  evidence-backed statement that the policy does not cover apply_patch edits.
- Extend `tests/agent-hooks-pi-adapter.test.ts` with the codex dialect beside
  the builtin one, and add the wire shapes to
  `home/dot_local/lib/agent-hooks/fixtures.ts` so the corpus keeps stating what
  each client sends.
- Re-run the live check: with the full package set and `openai-codex` selected,
  a `status=$?` command must come back denied. Today it does not.

## Open decisions

- Whether the registry stays a single static profile per client or grows a
  notion of provider-conditional tool surfaces. A single profile listing both
  spellings is the smaller change and matches KTD6's "no field the code does not
  consume"; a provider dimension would be new machinery for one observed case.
- Whether apply_patch edits are in scope for test-oracle-guard at all. Declining
  is defensible, but it must be recorded as evidence-backed inapplicability
  rather than left as an unmapped tool.
