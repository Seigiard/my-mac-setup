---
name: implement-spec
description: "Implement a spec's ticket graph through the tdd chain in separate worktrees, merge it into an integration branch, and close with code-review. Use when implementing a spec or set of tickets."
---

# Implement a spec

1. Read the spec and its tickets as a task graph. A ticket is ready when all its blockers are done; the frontier is the set of ready tickets. When no issue tracker was named, ask the user.
   Done when the graph, blockers, and current frontier are known.

2. Create one run directory at `~/.claude/artifacts/<run-id>/` for the spec. Use one `<ticket>/` subdirectory per ticket and pass it to `tdd` as that ticket's caller run directory.
   Done when the run directory and ticket directories exist.

3. Optionally start a fresh low-tier child to explore the codebase and external docs needed by the tickets. It writes `<run-dir>/exploration.report.md` atomically. Pass that path with each ticket to `tdd`, so it records the pointer in that ticket's `ticket.md`. Start children as described in the `tdd` skill's Dispatch section.
   Done when exploration is complete, or the decision to skip it is recorded.

4. Create the integration branch. If the tracker closes work through pull requests, or the user asks for one, open a draft PR after the first merge and make it close the spec and its tickets.
   Done when the integration branch exists and any requested draft PR is open.

5. For each frontier ticket, create a worktree and ticket branch from the integration branch tip with `git worktree add -b <ticket-branch> <path> <integration-branch>`. Run the `tdd` chain there as that ticket's orchestrator. Several frontier tickets may run at once.
   Done when each frontier ticket has a running or completed chain in its own worktree.

6. Per ticket, run only the chain's validation. Do not run a per-ticket review. If a chain exhausts its escalation ladder, mark the ticket blocked; its dependents wait, the independent frontier continues, and ask the user at once with the ticket, run directory, and reason. If a child cannot start, report its reason and run directory to the user and stop. Do not wait for other chains before asking.
   Done when every completed chain is validated or every stopped chain is reported as blocked.

7. When a chain succeeds, merge its ticket branch into the integration branch yourself with `git merge --no-ff`. A clean merge needs no child. If the merge conflicts, abort it with `git merge --abort` and start a fresh medium-tier child to redo the merge, resolve the conflicts, and commit.
   Done when each successful ticket is merged or its conflict child has been started.

8. After a conflict resolution, confirm each locked path equals its `lock_sha` version. For a path that an already-merged ticket also changed, read the resolved file and confirm both tickets' tests survive unchanged. Then run every merged ticket's test command on the integration tip. A failed check rejects the resolution: reset the integration branch to its pre-merge tip and start a fresh child one tier higher, medium then high. A high-tier failure blocks the ticket.
   Done when the merge passes the lock and green checks, or the ticket is blocked with its reason.

9. After the frontier advances, start chains for newly ready tickets. Continue until every ticket is merged or blocked and the user has decided how to handle each blocked ticket.
   Done when no ready or undecided ticket remains.

10. Run every merged ticket's test command and applicable checks on the integration tip. Then call the Skill tool with `code-review` on the integration branch once. Defer review route and fix routing to `code-review`.
    Done when final validation and the one closing review are complete.

11. Mark the draft PR ready, or resolve the tickets according to the issue tracker's close rule. Clean up the ticket worktrees and report the integration branch.
    Done when the spec is closed according to the tracker and cleanup is complete.
