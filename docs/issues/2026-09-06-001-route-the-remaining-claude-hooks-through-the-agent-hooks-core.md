---
title: "Route the remaining Claude hooks through the agent-hooks core"
short_description: "Four Claude-owned hooks still each carry their own settings entry and bash script (context-threshold.sh on Stop, handoff-pre-compact.sh on PreCompact, handoff-session-start.sh on SessionStart, herdr-worktree-identity-hook.sh on UserPromptSubmit); folding them into the dispatch core means extending its event model past tool calls, which the agent-hooks plan's R2 excluded on purpose, and the allow/block/context outcome triple does not describe what a Stop or SessionStart hook returns."
type: "follow-up"
category: "agent-platform"
tags: ["agent-hooks","claude-code","hooks","consolidation"]
date: "2026-09-06"
status: "open"
priority: "low"
---

## Why this exists

The cross-agent hooks core (`docs/plans/2026-09-03-0833-feat-agent-hooks-core-plan.md`)
collapsed four `PreToolUse` policies into one dispatcher: `~/.claude/settings.json` now
carries a single matcher pointing at `agent-hooks-dispatch.sh`, and which policy runs for
which tool is data in `home/dot_local/lib/agent-hooks/registry.ts`. Adding a fifth
tool-call policy costs one core entry.

Every other Claude hook this repository owns still predates that. Each one is its own
`settings.json` entry plus its own bash script, with its own argument parsing, its own
failure behaviour, and no shared selfcheck:

| Script | Event |
|---|---|
| `context-threshold.sh` | `Stop` |
| `handoff-pre-compact.sh` | `PreCompact` |
| `handoff-session-start.sh` | `SessionStart` |
| `herdr-worktree-identity-hook.sh` | `UserPromptSubmit` |

That is the same shape the tool-call policies had before the migration, so the question is
whether the same answer applies. It is not obvious that it does, which is why this is an
open question rather than queued work.

Two things make it a real design decision and not a mechanical move:

- **The core's event model stops at tool calls by design.** Requirement R2 of the plan
  scoped normalization to `test-oracle-guard`, `zsh-reserved-name-guard`, `fff-grep-guard`,
  `webfetch-markdown-hint` and `agents-local`, stating "No other events are normalized."
  `NormalizedEvent` carries a tool kind and its arguments; a `Stop` or `SessionStart`
  payload has neither.
- **The outcome triple does not fit.** The core returns `allow` / `block` / `context`
  (KTD2, KTD8). A `SessionStart` hook injects context and cannot block; a `Stop` hook
  decides whether the session may finish; `UserPromptSubmit` can both inject and reject.
  Reusing the existing three verdicts would either stretch their meaning or need a second
  outcome family.

There is also a motive question. The core exists so a policy written once reaches Claude
Code, OpenCode and Pi (KTD1: a policy never names a client). These four hooks are Claude
concepts — OpenCode and Pi have no `PreCompact` — so consolidating them buys uniform
plumbing (one fail-open invariant, one selfcheck, one subprocess, one place to look), not
cross-client parity. Whether that is enough to justify widening the core is the decision
this issue holds.

## Scope

In scope: a decision, and the work that follows from it, covering the four Claude-owned
hooks listed above.

Out of scope:

- `herdr-agent-state.sh` (`SessionStart`) — installed and overwritten by herdr itself,
  unmanaged by chezmoi, already named as a carve-out in the plan's Scope Boundaries.
- `file-suggestion.sh` and `statusline.sh` — wired through the top-level `fileSuggestion`
  and `statusLine` keys, not through `hooks`; a different integration point with a
  different contract.

Should the answer be to consolidate, the work is: extend the core's event model and
outcome set to cover the chosen events, port each script's logic into a core module, add
the events to the deployed shim, generalize the matcher-versus-registry union test in
`tests/bashunit/scripts_test.sh` so a wired-but-unregistered event still fails loudly, and
retire the old scripts through `.chezmoiremove` on the two-apply schedule KTD9 describes.

Should the answer be to leave them alone, record the reasoning where the next reader will
look for it and close this issue.

## Open decisions

- Does the core grow a second event family, or does it stay a tool-call dispatcher and
  these four hooks stay standalone?
- If it grows: one normalized-event type with optional fields, or a separate type per
  event family?
- What replaces `allow` / `block` / `context` for events whose verdicts are not about
  permitting a call?
- Does KTD1 survive? These policies are Claude-only, so either the core admits
  single-client policies as a first-class case, or the registry's existing derived
  inapplicability (KTD8) already covers it by deriving them inapplicable everywhere else.
- Is one dispatcher process per event still cheap enough? The tool-call path measured
  13-16 ms cold; `UserPromptSubmit` fires on every prompt.
