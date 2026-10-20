---
name: implement
description: "Build one ticket, either an issue reference or a described piece of work, through the tdd chain and close with code-review. Use when implementing one ticket, issue, or focused piece of work."
---

# Implement one ticket

1. If the user gives an issue reference, fetch the ticket from the issue tracker and state its title. Ask when the reference is ambiguous.
   Done when the ticket is identified or the user has been asked to clarify it.

2. Run `git status --porcelain --untracked-files=all`. When it is empty, continue. Otherwise read each dirty change against the behavior the ticket asks for. Carry-over is a complete, uncommitted change that does not implement the ticket and whose ownership is clear. When every change is carry-over, commit them in one commit, `chore: carry over <summary> before <ticket-id-or-slug>`, and tell the user in one line which paths it holds. Otherwise, report the dirty paths and stop.
   Done when the worktree was clean on entry, `git status --porcelain --untracked-files=all` is empty after the commit, or the dirty paths have been reported and execution has stopped.

3. Record `start_sha` (`git rev-parse HEAD`). Call the Skill tool with `tdd` on the current branch. Pass the ticket and use its issue number as the run-directory ticket name, or a short slug for described work.
   Done when `start_sha` is recorded and the chain has built and validated the ticket, or has reported why it stopped.

4. If the chain stops, no child can start, or the worktree is dirty, report the reason and run directory to the user and stop. The caller writes no code itself.
   Done when the stop reason and run directory are reported, or the chain reports success.

5. After the chain reports success, call the Skill tool with `code-review` on the branch.
   Done when `code-review` reports its outcome.

6. Organize the ticket commits by concern. Skip this step, and say so in the report, when `code-review` reported blocked, when the branch has an upstream (`git rev-parse @{u}` succeeds), or when a remote already holds the tip (`git fetch`, then `git branch -r --contains HEAD` is non-empty). Otherwise keep the chain reachable: create `refs/tdd/<run-id>/chain` once (`git update-ref refs/tdd/<run-id>/chain HEAD ""` creates it only when it does not exist), and on re-entry reuse the existing ref. Then `lock_sha`, the run directory's evidence, and a later `code-review` entering the chain mid-way still find their commits. Record `start_sha` and the ref in `ticket.md`, then `git reset --soft <start_sha>` and commit the tree in slices by `~/.claude/shared/commits.md`; when a lock exists, the lock's paths are the test slice, and the implementation is a second slice. Record the new tip in `ticket.md`.
   Done when the step was skipped with its reason, or `git diff refs/tdd/<run-id>/chain` is empty, the worktree is clean, `git log <start_sha>..HEAD` shows only the slices, and `ticket.md` records the ref and the new tip.

7. Report the run directory, the chain result, the review outcome, and the commit slices.
   Done when the implementation and review results are reported.
