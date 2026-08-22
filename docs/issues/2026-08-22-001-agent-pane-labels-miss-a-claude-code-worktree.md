---
title: "Agent pane labels miss a Claude Code worktree"
short_description: "herdr-task-sync resolves an agent pane's location from the pane process cwd, which Claude Code does not change when a session enters a git worktree, so the tab shows the base branch while Claude's own statusline shows the worktree branch."
type: "bug"
category: "herdr"
tags: ["herdr-task-sync","worktree","labels","claude-code"]
date: "2026-08-22"
status: "open"
priority: "medium"
---

## Why this exists

A pane running a Claude Code agent shows the **base** branch in its herdr label, even
when the agent's session is working inside a git worktree on a different branch.
Claude Code's own statusline, in the same pane, shows the worktree branch. The two
disagree, and the herdr side is the wrong one.

This defeats the purpose of the worktree identity shipped by
`docs/issues/2026-08-18-025-harden-herdr-task-sync-and-show-worktree.md`: parallel
agents on different worktrees are exactly the case the labels were meant to
distinguish, and agent panes are the case where the label is wrong.

### Observed instance

Tab `wB:t2C` held two panes on the same worktree, one agent and one plain shell:

| pane | contents | OS cwd of the pane process | `branch` token herdr-task-sync published |
|---|---|---|---|
| `wB:p5T` | Claude Code agent | `/Users/seigiard/Projects/my-mac-setup` | `main` |
| `wB:p5W` | plain zsh | `.../.claude/worktrees/perf-parallel-bats-suite` | `perf-parallel-bats-suite` |

The agent's session was in the worktree: `git worktree list` showed
`perf-parallel-bats-suite`, and the Claude statusline in that pane read
`perf-parallel-bats-suite [perf-parallel-bats-suite]`.

Reproduce the split with:

```sh
herdr pane process-info --pane <agent-pane-id>   # claude pid, cwd = base checkout
herdr pane list                                  # tokens.branch = base branch
```

The plain-shell pane is the control: it resolved correctly because a shell that
`cd`s into a worktree really does move its OS cwd. That confirms the mechanism is
cwd-based and works whenever cwd actually moves.

### Causal chain

1. Entering a worktree in Claude Code changes the **session's** logical directory
   (`workspace.current_dir`), not the OS cwd of the `claude` process. Verified: pid
   `98030` in pane `wB:p5T` had cwd `/Users/seigiard/Projects/my-mac-setup` while its
   session worked in `.claude/worktrees/perf-parallel-bats-suite`.
2. Claude Code's statusline reads the session value, so it is right.
   `~/.claude/hooks/statusline.sh:35` takes `.workspace.current_dir`; line 42 runs
   `git -C "$CURRENT_DIR" --no-optional-locks branch --show-current`.
   Source in this repo: `home/private_dot_claude/hooks/executable_statusline.sh`.
3. `resolve_pane_location` in `home/dot_local/bin/executable_herdr-task-sync:686`
   reads the pane's OS cwd. Lines 698-703 pick `.foreground_cwd` for a pane with no
   agent and `.cwd` for a pane with an agent. Both are OS-level, and for a Claude
   pane both point at the base checkout.
4. `build_worktree_tokens` and the publish path at
   `home/dot_local/bin/executable_herdr-task-sync:1615-1626` then emit `repo`,
   `worktree`, `branch`, `git_ref` from that wrong directory, via
   `herdr pane report-metadata --source location-sync`.
5. No channel carries the agent's real directory to herdr. The herdr Claude
   integration hook `~/.claude/hooks/herdr-agent-state.sh`
   (`HERDR_INTEGRATION_ID=claude`, version 8) sends only `pane.report_agent_session`
   with `session_id` and `transcript_path`. The repo's own adapter
   `home/private_dot_claude/hooks/executable_herdr-task-sync-hook.sh` forwards prompt,
   session, and compact events to the naming engine and likewise carries no cwd.

This is not a herdr core defect. `herdr-task-sync` in this repo owns the location
tokens, so the fix belongs here.

## Scope

- Give an agent pane a location source that reflects the agent's session directory
  rather than the pane process cwd, and keep the cwd path for non-agent panes.
- Keep `herdr-task-sync` the only writer of `repo`, `worktree`, `branch`, `git_ref`.
  Do not add a second publisher beside it.
- Fall back to the pane cwd when no session directory is available, so a non-Claude
  agent, a pre-hook window, or a stale record degrades to today's behavior instead
  of clearing the tokens.
- Refresh when the session directory changes, not only on the 5 s sweep. An agent can
  enter or leave a worktree mid-session.
- Add a test for an agent pane whose session directory and pane cwd disagree,
  asserting the published `branch` and `worktree` follow the session directory.
- Decide whether the opencode and pi adapters need the same treatment.
  `home/private_dot_config/opencode/plugins/herdr-task-sync.ts` and
  `home/dot_pi/agent/extensions/herdr-task-sync.ts` feed the same engine; whether
  those agents move their process cwd on a worktree switch is unverified.

### Groundwork already verified

- `pane.report_metadata` accepts arbitrary tokens: `maxProperties: 16`, names matching
  `^[A-Za-z0-9_-]{1,32}$` (`herdr api schema --json`, `$defs.PaneReportMetadataParams`).
- Overriding `branch`, `git_ref`, and `worktree` through it works. Probed live on pane
  `wB:p5R`; `--clear-token` removed the overrides and the cwd-derived values returned
  on their own within seconds. No permanent state was left behind.
- CLI argument order gotcha: the working form is
  `herdr pane report-metadata <PANE_ID> --source <ID> --token k=v`. The order printed
  in the built-in usage (`[OPTIONS] --source <ID> <PANE_ID>`) fails with
  `unknown option: <source value>`.

## Open decisions

- **Where the session directory comes from.** Two candidates, neither tested.
  The statusline hook already receives `.workspace.current_dir` on every render and
  runs in the agent's own process, so it could publish the location directly — but
  that puts a second writer beside `herdr-task-sync`, which the scope above forbids,
  unless it instead feeds the engine. The alternative is for
  `herdr-task-sync-hook.sh` to record the directory from its hook payload; whether the
  prompt, session, and compact payloads carry a directory that follows a worktree
  switch is unverified.
- **Whether the tab label picks the change up.** During the live probe, overriding the
  `git_ref` token did not change the tab label reported by `herdr tab list` within the
  observation window. Tab labels are composed separately by `compose_tab_intents`
  (`home/dot_local/bin/executable_herdr-task-sync:1142`). Confirm the composed tab
  label re-derives from the new tokens before treating a token-only fix as complete.
