# Direct build - no epic PR

The mode `/pf-build` runs when the user skips the spec step, or the change is small and self-contained enough that a spec-and-sub-task ceremony is pure overhead. It remains a first-class mode.

- The spec is the research narrative or the user's change, written to a canonical local plan file (`~/.claude/artifacts/<topic>/plan.md` or scratchpad). There are no sub-task files.
- Contracts and code ship together in implementation PRs based on `main`. Follow each affected contract's "Making Changes", rebuild touched artifacts, and commit them with the code.
- The PR, or each slice when scale requires it, runs through the `tdd` chain on its feature branch, then `code-review` on that branch. The orchestrator pushes and opens the PR after validation.
- Because the PR base is `main`, real CI runs and is the gate. Keep full diff review, local typechecks, named tests, contract-artifact discipline, and Greptile triage.
- Always publish the demo for a direct-build PR. Scale the walkthrough to the change, but include repro-to-resolution evidence.
- The orchestrator opens the PR and the user reviews and merges it.
