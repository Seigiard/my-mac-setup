---
title: "Add manual AgentBox sessions to Herdr without requiring a pipeline"
short_description: "Manage AgentBox and its Herdr plugin through chezmoi for interactive isolated sessions; upstream verified 2026-09-06 (madarco/agentbox, MIT, herdr-plugin.toml, fork/claude/codex/opencode/pi commands), but blocked on two decisions: this repo has no managed path for a pinned npm-global package, and 'agentbox install' writes host agent skills into chezmoi-owned destinations."
type: "follow-up"
category: "herdr"
tags: ["herdr","follow-up"]
date: "2026-08-18"
status: "open"
priority: "low"
---

## Why this exists

Some coding tasks need an interactive isolated environment rather than an ordinary worktree. A
person may need to open the `platform` project, move the current agent conversation into a fresh
isolated environment, work interactively and watch that agent in Herdr. The current child-agent
launch contract creates visible Herdr panes and worktrees, but it does not create a container or
virtual machine boundary around those panes.

AgentBox provides the missing manual lifecycle. Its `fork` command moves a supported current agent
session into a new box, while its `claude`, `codex` and `opencode` commands start fresh agents in a
box. Its Herdr plugin exposes boxes, agent status and attach actions directly.

The integration cannot be installed verbatim from upstream instructions. This repository owns the
live Herdr and agent configuration through chezmoi, so a plugin installer that edits live config
would create drift. AgentBox also shares host-side git metadata and selected agent identity state;
those boundaries need explicit tests before the box can be treated as containment.

## Scope

Add a source-managed AgentBox integration for manual interactive work:

- Install a pinned AgentBox release through this repository's normal tool-management path.
- Install or vendor the Herdr plugin without mutating `~/.config/herdr` directly. Manage plugin
  files, keybindings and any required status configuration from the sources under `home/`.
- Provide one command and one Herdr action for `agentbox fork`, where "fork" means moving the
  current supported agent session into a new box. It does not mean forking the git repository.
- Provide one command and one Herdr action for starting a fresh `claude`, `codex` or `opencode`
  session in a named box for the current project.
- Make each box visible in Herdr with its project, branch, agent kind, lifecycle status and an attach
  action. The agent terminal must remain interactive after launch.
- Use one per-box branch and the documented AgentBox host-side git flow. A user must be able to
  inspect a box diff from the host, retain the branch after stopping the box and push deliberately.
- Default to the narrowest practical carry and credential policy. Do not carry project `.env` files,
  AWS credentials, SSH keys, 1Password state or unrelated agent history unless a project profile
  declares and explains the requirement.
- Add a minimal project profile for `platform` in that repository, not in chezmoi. The profile should
  declare only project setup, services and validation commands that differ from the machine defaults.
- Document stop, destroy, stale-box recovery and branch cleanup. Destruction must not discard the
  only copy of an unpushed diff without an explicit confirmation.

## Success criteria

- From an interactive agent in the `platform` checkout, one documented action creates a new box,
  moves the session into it and opens or exposes it in Herdr.
- From a normal project shell, one documented action starts a fresh supported agent in a box.
- Herdr shows the box and agent state accurately across attach, detach, stop, restart and destroy.
- A filesystem probe can change the box worktree but cannot read an uncarried host-home marker or an
  unrelated project checkout.
- A credential inventory proves which host files, sockets and environment variables enter the box.
  No undocumented credential path enters by default.
- The host can inspect and deliberately push the box branch after the agent exits. Stopping or
  destroying the box does not lose an unreviewed diff silently.
- The integration has smoke tests for managed files and does not make `chezmoi diff` report live
  config changes caused by the AgentBox installer.

## Relationship to existing issues

This is the manual interactive implementation track for
`docs/issues/2026-08-18-002-sandbox-a-child-agents-filesystem-access.md`. The shared issue should
remain open until tests prove that AgentBox contains the broad opencode read grant and until any
non-AgentBox launch path has an explicit policy.

`docs/issues/2026-08-18-001-launch-time-permission-mode-for-child-agents.md` still controls what an
agent may do inside its assigned workspace. AgentBox controls what host resources that workspace can
reach. Both boundaries apply to a manual child agent.

## Open decisions

- Whether the local Docker provider is a sufficient boundary for routine interactive work, or
  whether sensitive tasks require an AgentBox remote virtual-machine provider.
- Which agent authentication mechanism avoids mounting long-lived credential files while keeping
  `claude`, `codex` and `opencode` usable after `fork`.
- Whether `agentbox fork` should be the default manual action or an explicit escalation from the
  existing worktree-only child launch flow.
- Which parts of the `platform` profile belong in its existing devcontainer configuration and which
  AgentBox-specific declarations require a separate `agentbox.yaml`.

## Upstream surface verified (2026-09-06)

The record was written without anyone here checking AgentBox, so the sweep checked it before
deciding. Upstream is `github.com/madarco/agentbox`, MIT, carrying a `herdr-plugin.toml` at its root
and the `herdr-plugin` GitHub topic, so the Herdr integration this record assumes does exist.

The CLI surface is real and slightly wider than the record describes. `apps/cli/src/help.ts` groups
`create`, `attach`, `fork`, `claude`, `codex`, `opencode` and `pi` under "Create & run", with `fork`
documented as "Fork the current host agent session into a new box and resume it there" — the exact
capability the Scope asks for. Note `pi` is supported upstream, which this record does not mention
and which matters because this machine runs Pi. Boxes also expose `shell`, `url`, `screen`, `code`
and `dashboard`, and providers include local Docker, remote Docker, Hetzner, Vercel, Daytona and E2B.

Two verified facts block the Scope as written rather than merely complicating it:

- **Distribution is npm-global** (`npm -g install @madarco/agentbox`), plus Docker and Node >= 20.10
  as host requirements. The Scope says to install a pinned release "through this repository's normal
  tool-management path", and this repository has no managed path for a pinned npm-global package —
  Brewfiles, mise and `.chezmoiexternal.toml` are the three that exist. Which of those absorbs it, or
  whether a fourth is created, is a decision nobody has made.
- **`agentbox install` writes host agent skills.** Upstream ships `apps/cli/share/host-skills/` for
  agentbox, codex and opencode, and the CLI prints a tip telling the user to run `agentbox install`
  to enable the `/agentbox` fork command in host Claude. Those destinations are chezmoi-owned here,
  so running the vendor installer is precisely the "installer-driven config drift" this record set
  out to avoid. Vendoring the plugin and skills into `home/` instead is possible but is a design
  decision with an ongoing upstream-sync cost.

Neither is a blocker a one-shot attempt could resolve, and the Scope additionally reaches outside
this repository (a project profile for `platform`, in that repository) and depends on two open
`agent-platform` records. The item stays open pending those decisions.
