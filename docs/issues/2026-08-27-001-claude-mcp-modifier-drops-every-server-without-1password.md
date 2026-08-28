---
title: "Claude MCP modifier drops every server without 1Password"
short_description: "home/modify_dot_claude.json early-exits and echoes stdin unchanged when op or jq is missing or a key comes back empty, so credential-free servers (deepwiki, fff, executor) are also unregistered on a machine without 1Password rather than only the key-bearing ones."
type: "bug"
category: "agent-platform"
tags: ["mcp","chezmoi","onepassword"]
date: "2026-08-27"
status: "done"
priority: "medium"
closed: "2026-08-28"
---

## Why this exists

`home/modify_dot_claude.json` guards its whole body on 1Password:

```bash
if ! command -v op &>/dev/null || ! command -v jq &>/dev/null; then
  echo "$existing"
  exit 0
fi
```

and again on empty credentials. Either guard echoes stdin unchanged, so the
`jq` call that assigns `.mcpServers` never runs.

Only `jina` and `tavily-mcp` actually need a 1Password credential. `deepwiki`,
`fff`, and `executor` need none, but they share the gate's fate: on a machine
without `op` the modifier registers **no** MCP servers at all. The behavior is
covered by the control test "Claude settings modifier passes settings through
untouched without 1Password" in `tests/scripts.bats`, which documents it rather
than fixing it.

Impact is limited today because the only machine that applies this file has
1Password. It bites on a fresh machine bootstrapped before `op` is signed in,
where Claude Code silently comes up with zero tools.

## Scope

Split the `jq` assignment so the credential-free servers are always written and
only `jina` and `tavily-mcp` depend on the keys. Keep the existing pass-through
contract for a totally absent `jq`, since the script cannot build JSON without
it. Update the control test in `tests/scripts.bats` to assert the new split
instead of the current all-or-nothing behavior.

## Open decisions

Whether a machine with `op` present but not signed in should register the
credential-free servers and skip the rest, or fail loudly so the missing
sign-in is noticed.

## Resolution

Split the guard in home/modify_dot_claude.json: only a missing jq still passes stdin through, while deepwiki, fff, and executor are registered unconditionally and jina and tavily-mcp are added per credential, independently of each other. op present but answering nothing warns on stderr and skips that one server rather than failing the apply, so a missing sign-in stays visible without costing the rest of the apply. Covered in tests/scripts.bats by three cases: credential-free registration without op, per-credential independence with the stderr warning, and the surviving no-jq pass-through.
