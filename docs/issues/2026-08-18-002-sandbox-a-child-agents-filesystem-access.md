---
title: Sandbox a child agent's filesystem access
type: idea
date: 2026-08-18
status: open
parent-plan: docs/plans/2026-08-17-1630-feat-child-agent-launch-contract-plan.md
---

## Why this exists

The child agent launch contract opens opencode's reads to directories outside the worktree, in the shared config at `home/private_dot_config/opencode/opencode.json.tmpl`. The grant is deliberately unbounded by path, and it applies to every opencode session on the machine, including the user's own — that breadth is the point, because a curated allowlist has to be edited and re-applied every time a child needs a new path, and children kept stalling on exactly the paths nobody had added yet.

The plan accepts that breadth on one condition, stated in its Key Decisions: sandboxing the child is the next piece of work and will contain the grant, so a path-level bound written now would be superseded a single iteration later.

That condition had no file behind it. The plan's own dependency note prices the gap plainly: between applying the read grant and shipping a sandbox, every opencode session on this machine reads credential-bearing paths without a prompt. All three legs of the plan's review — the local one, an external review on claude, and an external review on opencode — independently flagged that the mitigation carrying the decision was untracked. This file is the tracking.

## Scope

Contain what a child agent can reach on the filesystem, so that opening its read permissions stops being a machine-wide grant.

Open shapes worth comparing:

- An OS-level sandbox around the child process (`sandbox-exec` on macOS, or whatever the platform's supported successor is), configured per launch from the child's worktree.
- A container or VM per child, which contains reads and writes together but costs startup time on every consult.
- A narrower read grant reinstated once something else removes the curation cost — for example, granting the paths a child actually asked for during its own run rather than pre-listing them.

Two constraints any shape has to satisfy. The child must still reach the return-channel command that lets it call its parent, since the launch contract makes that mandatory in every posture. And the user's own interactive opencode sessions must keep working unchanged — the read grant lives in shared config precisely because it helps them, so a sandbox that also fences the user is a regression, not a fix.

Related and deliberately separate: `docs/issues/2026-08-18-001-launch-time-permission-mode-for-child-agents.md` covers what a child may *do* inside its own worktree. This issue covers what it can *reach* outside one. They are different boundaries and either can ship first.

## Open decisions

- Which containment mechanism, given that consults are started interactively and startup latency is felt directly by the person waiting.
- Whether the read grant in the shared opencode config narrows again once a sandbox exists, or stays wide because the sandbox already bounds it.
- Whether the sandbox applies to every child or only to children a caller marks as untrusted.
- What happens to the headless opencode legs started by the smithers harness and by `pf-build`, which the launch contract does not cover and which today inherit the same wide read grant.
