---
title: "Add manual AgentBox sessions to Herdr without requiring a pipeline"
short_description: "Add manual AgentBox sessions to Herdr without requiring a pipeline"
type: "follow-up"
category: "herdr"
tags: ["herdr","follow-up"]
date: "2026-08-18"
status: "open"
priority: "low"
---

## Why this exists

Not every coding task should start a Smithers pipeline. A person sometimes needs to open the
`platform` project, move the current agent conversation into a fresh isolated environment, work
interactively and watch that agent in Herdr. The current child-agent launch contract creates visible
Herdr panes and worktrees, but it does not create a container or virtual machine boundary around
those panes.

AgentBox provides the missing manual lifecycle. Its `fork` command moves a supported current agent
session into a new box, while its `claude`, `codex` and `opencode` commands start fresh agents in a
box. Its Herdr plugin exposes boxes, agent status and attach actions without requiring Smithers to
own the session. This is a different use case from the sandboxed durable pipeline in
`docs/issues/2026-08-18-018-run-smithers-pipeline-agents-in-microsandbox.md`.

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

After the manual flow works, prove an optional pipeline-inside-box flow:

- Make the managed Smithers runtime and workflow catalog available inside the box without copying
  mutable host run state into it.
- Add an explicit AgentBox execution profile for Smithers. The profile must treat the AgentBox box as
  the outer isolation boundary and must not start a nested Microsandbox microVM by default.
- Verify that Smithers can create its own worktree or equivalent lane inside the box, run a bounded
  workflow and leave a branch and diff that the host can inspect.
- Decide how nested pipeline state reaches host Herdr. The outer AgentBox pane is not sufficient if
  Smithers node-level status disappears inside it.

## Success criteria

- From an interactive agent in the `platform` checkout, one documented action creates a new box,
  moves the session into it and opens or exposes it in Herdr.
- From a normal project shell, one documented action starts a fresh supported agent in a box without
  creating a Smithers run.
- Herdr shows the box and agent state accurately across attach, detach, stop, restart and destroy.
- A filesystem probe can change the box worktree but cannot read an uncarried host-home marker or an
  unrelated project checkout.
- A credential inventory proves which host files, sockets and environment variables enter the box.
  No undocumented credential path enters by default.
- The host can inspect and deliberately push the box branch after the agent exits. Stopping or
  destroying the box does not lose an unreviewed diff silently.
- A Smithers workflow can run from inside a box with nested microVM isolation disabled explicitly.
  Its result and branch remain available after the box stops.
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
- Whether a Smithers process inside the box can report node events to the host Herdr socket safely,
  needs a host relay, or should leave node-level Herdr visibility unsupported in the first release.
- Whether Smithers can safely create nested worktrees against AgentBox's shared host-side git
  metadata. If it cannot, the box needs a pipeline-specific clone or branch handoff.
- Which parts of the `platform` profile belong in its existing devcontainer configuration and which
  AgentBox-specific declarations require a separate `agentbox.yaml`.
