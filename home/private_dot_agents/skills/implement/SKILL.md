---
name: implement
description: "Build one ticket, either an issue reference or a described piece of work, through the tdd chain and close with code-review. Use when implementing one ticket, issue, or focused piece of work."
---

# Implement one ticket

1. If the user gives an issue reference, fetch the ticket from the issue tracker and state its title. Ask when the reference is ambiguous.
   Done when the ticket is identified or the user has been asked to clarify it.

2. Run `git status --porcelain --untracked-files=all`. When it is empty, continue. Otherwise read each dirty change against the behavior the ticket asks for. Carry-over is a complete, uncommitted change that does not implement the ticket and whose ownership is clear. When every change is carry-over, commit them in one commit, `chore: carry over <summary> before <ticket-id-or-slug>`, and tell the user in one line which paths it holds. Otherwise, report the dirty paths and stop.
   Done when the worktree was clean on entry, `git status --porcelain --untracked-files=all` is empty after the commit, or the dirty paths have been reported and execution has stopped.

3. Call the Skill tool with `tdd` on the current branch. Pass the ticket and use its issue number as the run-directory ticket name, or a short slug for described work.
   Done when the chain has built and validated the ticket, or has reported why it stopped.

4. If the chain stops, no child can start, or the worktree is dirty, report the reason and run directory to the user and stop. The caller writes no code itself.
   Done when the stop reason and run directory are reported, or the chain reports success.

5. After the chain reports success, call the Skill tool with `code-review` on the branch.
   Done when `code-review` reports its outcome.

6. Report the run directory, the chain result, and the review outcome.
   Done when the implementation and review results are reported.
