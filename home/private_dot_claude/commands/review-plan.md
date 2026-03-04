---
name: review-plan
description: |
  Multi-agent plan review with iterative debate and consensus scoring.
  Spawns 4 agents (Architect, Skeptic, Pragmatist, Synthesizer) to review plans through parallel analysis and scoring.
  Auto-revises plan on REVISE verdict until APPROVED or 5 iterations.
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

Multi-agent plan review with automatic revision loop.

## SETUP

1. Parse `$ARGUMENTS`:
   - If it's a file path → read the file as the plan
   - If it's quoted text → save to `docs/plans/YYYY-MM-DD-<slug>.md`, then use that file
2. Read all 4 agent persona files from `~/.claude/agents/plan-*.md` (architect, skeptic, pragmatist, synthesizer)
3. Store the plan file path — you will update this file on REVISE

## ITERATION LOOP (max 5 iterations)

For each iteration:

### Phase 1 — Parallel Review

Launch 3 agents **in parallel** (single message, 3 Agent tool calls):

- **Architect** (`plan-architect`): subagent_type=`plan-architect`, model from agent file
- **Skeptic** (`plan-skeptic`): subagent_type=`plan-skeptic`, model from agent file
- **Pragmatist** (`plan-pragmatist`): subagent_type=`plan-pragmatist`, model from agent file

Each agent receives:
- The agent's system prompt (from its `.md` file)
- The current plan text
- The iteration number
- Previous iteration feedback (if iteration > 1)

### Phase 2 — Synthesis

Launch the **Synthesizer** agent (subagent_type=`plan-synthesizer`) with:
- All 3 reviewer reports from Phase 1
- The current plan text
- Previous iteration scores (if iteration > 1)

### Phase 3 — Route Verdict

Parse the Synthesizer's JSON response and act based on `verdict`:

#### APPROVED (score >= 20)
- Display final scores, key findings, and summary to user
- Show the iteration count: "Plan approved after N iteration(s)"
- **STOP** — loop ends

#### REJECT (score < 15)
- Display scores, key findings, summary, and revision guidance to user
- Explain that the plan has fundamental issues requiring user intervention
- **STOP** — loop ends, ask user how they want to proceed

#### REVISE (score 15-19)
- Display current scores and key findings summary (brief — 3-5 lines)
- **Automatically apply revisions:**
  1. Read `revision_guidance` and all reviewer findings
  2. Update the plan file: address each piece of guidance while preserving the plan's intent and structure
  3. Show a brief diff summary of what changed (1-2 sentences)
  4. **Continue to next iteration** — do NOT ask the user for permission

## CRITICAL RULES

- **REVISE = automatic.** On REVISE verdict, apply the revision guidance to the plan file yourself and immediately proceed to the next iteration. Never stop to ask the user "should I revise?" or "handle the comments."
- **Only stop on APPROVED, REJECT, or iteration 5.** If iteration 5 produces REVISE, treat it as the final result — display all findings and let the user decide.
- **Preserve plan intent.** When revising, fix the issues raised by reviewers but do not change the fundamental approach unless a reviewer explicitly calls for it.
- **Show progress.** At each iteration, display: `## Review Iteration N/5` with a brief status line.
- **Cumulative context.** Each iteration's agents receive the previous iteration's feedback so they can verify fixes.
