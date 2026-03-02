---
name: review-plan
description: |
  Multi-agent plan review: 4 agents debate until consensus.
  Usage: /review-plan <file.md> or /review-plan "plan text"

  <example>
  <user>/review-plan docs/plans/2026-03-02-review-plan-design.md</user>
  <assistant>Starting multi-agent review of docs/plans/2026-03-02-review-plan-design.md...
  ## Review Iteration 1/5
  [launches 3 parallel agents]</assistant>
  </example>

  <example>
  <user>/review-plan "Build a REST API with auth, rate limiting, and caching"</user>
  <assistant>Saved plan to docs/plans/2026-03-02-rest-api-plan.md
  Starting multi-agent review...
  ## Review Iteration 1/5</assistant>
  </example>
---

Multi-agent plan review with iterative debate and consensus scoring.

Use the `review-plan` skill to orchestrate 4 agents reviewing the plan provided in `$ARGUMENTS`.

Follow the skill protocol exactly:
1. Parse input (file path or text)
2. If text — save to docs/plans/
3. Read all 4 agent files from ~/.claude/agents/plan-*.md
4. Run the iteration loop (Phase 1 parallel → Phase 2 synthesis → route verdict)
5. Continue until APPROVED, REJECT+user stop, or max 5 iterations
