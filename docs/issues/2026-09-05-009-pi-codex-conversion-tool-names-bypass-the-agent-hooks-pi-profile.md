---
title: "Pi codex-conversion tool names bypass the agent-hooks pi profile"
short_description: "Pi's profile now maps exec_command to bash and reads input.cmd, with adapter regression coverage and a live Pi 0.85.1/openai-codex denial confirming policies reach real Codex-provider shell calls."
type: "bug"
category: "agent-platform"
tags: ["agent-hooks","pi","tool-identifiers","codex"]
date: "2026-09-05"
status: "done"
priority: "high"
closed: "2026-09-12"
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
  `input.command`. The `apply_patch` half is no longer urgent: `test-oracle-guard`
  was the only policy on `edit`/`write` and was retired (`2026-09-02-011`), so no
  shipped policy currently reads edit content on any client. Map `apply_patch`
  only when a policy needs it, and decide the patch-envelope parsing then.
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
- Whether `apply_patch` needs a mapping while no policy watches `edit`/`write`.
  Leaving it unmapped is defensible now that `test-oracle-guard` is retired, but
  it must be recorded as evidence-backed inapplicability rather than left as a
  silently unmapped tool.

## Confirmed live (2026-09-06)

Previously inferred from reading the provider configuration. Now observed
directly in a running Pi session against the applied core:

```
> run this exact bash: status=$(echo hi)
  • Ran  status=$(echo hi)
  Command completed with exit code 0.
```

The identical prompt is denied in Claude Code and in OpenCode with
`zsh-reserved-name-guard:`. In Pi it executed.

The same session's selfcheck reports `pi: current` with three green `@ pi`
canaries. Both statements are true and neither contradicts the other: the
adapter loads, the core is the deployed one, and the canaries dispatch synthetic
events carrying the registry's tool names. No real Pi tool call ever carries
those names, so every canary-green route is unreachable in practice.

That is the sharpest form of this issue. R8 says selfcheck detects a fully dead
path, not an unreachable one, and this is what an unreachable path looks like
from the outside: entirely green.

## Resolution

Mapped Pi's observed exec_command tool to the canonical bash kind, normalized input.cmd alongside builtin input.command, and added calibrated core and adapter coverage with an ordinary-variable control. Verified the regression red before the mapping, both focused suites green afterward, make test-local mapped the managed files as expected, make test-ubuntu passed, and a live Pi 0.85.1 session with openai-codex plus pi-codex-conversion 3.0.33 emitted exec_command/input.cmd and received the zsh-reserved-name-guard denial. apply_patch remains intentionally unmapped until a shipped edit/write policy has a verified envelope parser.
