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

5. For each frontier ticket, create a worktree and ticket branch from the integration branch tip with `git worktree add -b <ticket-branch> <path> <integration-branch>`. That command runs no setup hook, so prepare the checkout with `~/.local/bin/herdr-worktree-setup-run <path>` and wait for exit 0. Pass no branch: fresh-base is then skipped and the ticket branch stays on the integration tip. When the runner logs `no configuration`, seed what the repository's `AGENTS.md` asks for instead. A non-zero exit is a child that cannot start; step 6 applies. Run the `tdd` chain there as that ticket's orchestrator. Several frontier tickets may run at once.
   Done when each frontier ticket's runner exited 0 and its chain is running or complete, or the ticket is reported under step 6.

6. Per ticket, run only the chain's validation; the one review runs in step 10. If a chain stops, mark the ticket blocked and keep its report; its dependents wait and the independent frontier continues. A blocked ticket is remaining work for the step 11 report, with its reason and run directory; a chain that stopped on a **Decision** carries its question there as a decision brief (read `~/.claude/shared/decision-brief.md` before drafting it). If a child cannot start, report its reason and run directory to the user and stop.
   Done when every completed chain is validated and every stopped chain is recorded as blocked.

7. When a chain succeeds, merge its ticket branch into the integration branch yourself with `git merge --no-ff`. A clean merge needs no child. If the merge conflicts, abort it with `git merge --abort` and start a fresh medium-tier child to redo the merge, resolve the conflicts, and commit.
   Done when each successful ticket is merged or its conflict child has been started.

8. After a conflict resolution, confirm each locked path equals its `lock_sha` version. For a path that an already-merged ticket also changed, read the resolved file and confirm both tickets' tests survive unchanged. Then run every merged ticket's test command on the integration tip. A failed check rejects the resolution: reset the integration branch to its pre-merge tip and start a fresh child one tier higher, medium then high. A high-tier failure blocks the ticket.
   Done when the merge passes the lock and green checks, or the ticket is blocked with its reason.

9. After the frontier advances, start chains for newly ready tickets.
   Done when every ticket is merged, blocked, or waiting on a blocked ticket.

10. Run every merged ticket's test command and applicable checks on the integration tip. Then call the Skill tool with `code-review` on the integration branch once. Defer review route and fix routing to `code-review`.
    Done when final validation and the one closing review are complete.

11. When final validation passed, `code-review` finished unblocked, and no ticket is blocked, mark the draft PR ready, or resolve the tickets according to the issue tracker's close rule. Otherwise leave the PR draft and the blocked tickets open. Clean up the worktrees of merged tickets, keep those of blocked tickets, and report the integration branch, each blocked ticket with its reason or decision brief, and the review's remaining work.
    Done when the PR and tickets are in the state above, cleanup is complete, and the report is delivered.
