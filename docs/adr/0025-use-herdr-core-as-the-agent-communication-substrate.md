---
title: Use herdr-core as the agent communication substrate
status: accepted
date: 2026-11-03
supersedes:
  - 0017-intercept-herdr-resource-creation-with-a-path-wrapper
  - 0024-replace-agent-intercom-with-herdr-peer
---

# ADR-0025: Use herdr-core as the agent communication substrate

## Context

The Herdr desktop app runs every terminal through herdr-core and exports only
`HC_*` variables. `herdr-child`, `herdr-peer`, the resource tree, the context
hooks, and the TUI skills talk to the TUI server socket; they are inert in an
app terminal. Two systems therefore coexist, but one is dead where the person
works.

## Considered options

- Keep the TUI server for agent traffic. This preserves the existing tools but
  leaves app terminals without agent communication.
- Port the TUI tooling to the app's mod API. This keeps the app as a transport
  adapter and recreates state that herdr-core already owns.
- Adopt herdr-core's own primitives. This uses the transport, parent edge, and
  notes that the app terminals already provide.

## Decision

Use herdr-core as the agent communication substrate. A child is an `hc run`
terminal started from a template plus a task. `hc send` carries messages, and
the core tags them as `<hc from="…" reach="…">`. The core records the parent
edge and writes notes on `blocked`, `error`, and `exited`. Use `hc wait` for
waits inside a turn. The repository adds hc counterparts beside the TUI tools
and retires the TUI afterwards.

## Constraints from the owner's answers

- No message kinds: a question is an ordinary `hc send`; end the turn after it.
- Use color-animal child names from the pane-labels pool so terminal names and
  the sidebar agree.
- Use `--bg` by default; open a visible tab only on request.
- A parent may answer a child's question dialog with `hc send --force`; a
  permission decision still goes to the person.
- Keep `notes` on.
- The `ask-in-hc` copy was built and then withdrawn by the owner's decision on
  2026-11-04 in favour of hc's native flow: `hc-run` + `hc wait`, with the
  answer as an `<hc from>` message. A pi consult runs `pi` directly with
  `hc run -- …` + `hc send`, without a template.
- Ghostty no longer starts the TUI.
- Worktree setup runs without the server and is isolated by code.

## Consequences

- #609 established `~/.claude/shared/hc-agent-contract.md` and a
  `HC_TERMINAL_ID`-gated pointer to it in `~/.claude/CLAUDE.md`.
- #610 established templates in `~/.config/herdr-core/templates/` for the
  reviewer and implementer tiers.
- #611 established `hc-run` and `my-agents` showing pool-alias names; #612
  built the `ask-in-hc` copy, which the owner withdrew on 2026-11-04 in favour
  of hc's native flow; #613 established the `hc` skill and hc branches in tdd
  dispatch, pf-build, and pf-issue.
- #614 established the hc branch of `herdr-run`; #615 stopped Ghostty from
  starting the TUI; #616 established the `my-worktree` mod,
  `herdr-worktree-setup-run`, and the pinned external.
- During coexistence, the TUI sees no hc terminals and hc sees no TUI panes.
  Retirement is split between #617 (TUI-only tooling, resource tree, and
  worktree identity) and #618 (server, plugins, and launchd job); each needs
  the owner's go-ahead.
- `hc-run` sources `~/.local/lib/herdr-pane-labels/herdr-aliases.sh`. Today
  `seigi.pane-labels` installs that library, so #617 must keep or re-home it
  before the plugin goes.
- ADR-0019 stays rejected: one delivery owner per supervision generation is
  moot when the core owns the notes. ADR-0008 and ADR-0018 keep their
  decisions; the mechanism change is recorded in their Status sections.
