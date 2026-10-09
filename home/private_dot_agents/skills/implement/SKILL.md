---
name: implement
description: "Build one ticket, either an issue reference or a described piece of work, through the tdd chain and close with code-review. Use when implementing one ticket, issue, or focused piece of work."
---

# Implement one ticket

1. If the user gives an issue reference, fetch the ticket from the issue tracker and state its title. Ask when the reference is ambiguous.
   Done when the ticket is identified or the user has been asked to clarify it.

2. Call the Skill tool with `tdd` on the current branch. Pass the ticket and use its issue number as the run-directory ticket name, or a short slug for described work.
   Done when the chain has built and validated the ticket, or has reported why it stopped.

3. If the chain stops because it exhausted its ladder, no child can start, or the worktree is dirty, report the reason and run directory to the user and stop. The caller writes no code itself.
   Done when the stop reason and run directory are reported, or the chain reports success.

4. After the chain reports success, call the Skill tool with `code-review` on the branch.
   Done when `code-review` reports its outcome.

5. Report the run directory, the chain result, and the review outcome.
   Done when the implementation and review results are reported.
