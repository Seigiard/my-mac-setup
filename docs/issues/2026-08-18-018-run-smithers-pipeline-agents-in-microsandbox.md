---
title: Run Smithers pipeline agents in Microsandbox with Herdr visibility
type: follow-up
date: 2026-08-18
status: open
---

## Why this exists

The durable pipeline under `home/private_dot_claude/dot_smithers/` already owns worktrees, agent
stages, approvals, retries, structured output and guarded commits. It does not own an operating-system
boundary around the agents it starts. Those agents inherit the host filesystem and the broad read
grant tracked in `docs/issues/2026-08-18-002-sandbox-a-child-agents-filesystem-access.md`.

The local runtime is also one upstream generation behind the integration needed to close that gap.
`home/private_dot_claude/dot_smithers/package.json` pins `smithers-orchestrator@0.32.0`. Smithers
0.35 publishes the renamed `smthrs` package, a native Herdr mirror, `<Worktree>` and first-class
sandbox providers. The isolation research in
`docs/ideation/2026-08-18-agent-isolation-pov.html` recommends a bounded trial of that path before
introducing a second pipeline orchestrator.

The important integration claim is still unverified on this machine. A real macOS run must prove
that a Microsandbox node can return validated output and a usable diff, remain observable in Herdr,
and resume after interruption without exposing host credentials.

## Scope

Upgrade the managed Smithers runtime and adapt the existing workflows to the 0.35 API without
changing their durable ownership model:

- Replace `smithers-orchestrator@0.32.0` with a pinned compatible `smthrs@0.35.x` release. Migrate
  imports, scripts, trusted native dependencies and tests together.
- Preserve the existing run identifiers, approval gates, replay behavior, structured Zod envelopes,
  secret baselines and pipeline-owned guarded commits.
- Enable Smithers' native Herdr mirror for pipeline launches. Each running agent node must appear in
  Herdr with live output and authoritative status from the Smithers event stream.
- Add a local Microsandbox provider through Smithers' sandbox contract. Start with a throwaway
  workflow, then move the production work stage only after the trial gates pass.
- Give each sandbox only its assigned worktree, the required agent runtime, explicit setup commands
  and the minimum network and credential bindings. Do not mount the project parent, home directory,
  1Password state, SSH directory or unrelated repository worktrees.
- Keep machine integration in this repository: Smithers packages, the Microsandbox runtime, Herdr
  launch behavior and shared credential policy. Keep project-specific setup and validation commands
  in the target repository.
- Fail closed when a launch requests isolation but Microsandbox is unavailable. Tests may use a
  stub provider, but the interactive command must not silently fall back to an unsandboxed process.
- Document the supported cleanup and recovery path for a stopped run, an orphaned microVM and a
  worktree that still contains an uncommitted agent diff.

The first trial should use two small agents in separate worktrees. Each agent reads a bounded part of
the `platform` repository, runs one narrow validation command and returns Zod-validated output. A
second trial should permit one agent to change a fixture and prove that the host pipeline receives
the diff and commits it through the existing guarded path.

## Success criteria

- A clean install resolves the pinned Smithers 0.35 runtime on macOS and remains testable in the
  repository's Linux and Docker checks without requiring Microsandbox there.
- Starting the trial from Herdr creates visible node tabs, streams output and reports terminal status
  without a second status registry.
- An agent can read and change its worktree, but a probe cannot read a marker in the host home
  directory or another worktree.
- The write trial returns structured output and a complete diff. The existing pipeline guard, not
  the agent, creates the commit.
- Interrupting and resuming the run preserves Smithers state and does not grant broader filesystem
  access on replay.
- Failure and cancellation remove the sandbox resources. They retain only the documented run state,
  worktree and logs needed for recovery.
- Existing workflow unit tests, template tests and shell lint remain green.

## Relationship to existing issues

This is the headless pipeline implementation track for
`docs/issues/2026-08-18-002-sandbox-a-child-agents-filesystem-access.md`. It does not close that
issue because manually launched interactive child agents need a separate containment path. The
AgentBox track in `docs/issues/2026-08-18-019-add-manual-agentbox-sessions-to-herdr.md` covers that
path.

## Open decisions

- Whether `<Sandbox>` should wrap `<Worktree>` or the worktree should be created on the host and
  mounted into the sandbox. The choice must preserve host-side git metadata and guarded commits.
- Whether one microVM should live for the full durable run or each agent node should receive a new
  microVM. Per-node isolation is stronger, but it increases setup cost and state-transfer work.
- Which network destinations and agent credentials each stage actually needs, and how Smithers binds
  them without copying long-lived secrets into the sandbox filesystem.
- Whether review and simplify stages move into Microsandbox after the work-stage trial, or remain
  host processes with a narrower read-only policy.
- Whether Smithers' Herdr mirror is sufficient for intervention, or whether a safe interactive hijack
  path is also required before rollout.
