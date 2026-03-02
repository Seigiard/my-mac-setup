---
name: review-plan
description: |
  Multi-agent plan review with iterative debate and consensus scoring.
  Spawns 4 agents (Architect, Skeptic, Pragmatist, Synthesizer) to review plans through parallel analysis and scoring.
  Use when user invokes /review-plan or wants adversarial review of a plan.
---

# Review Plan — Multi-Agent Debate Protocol

Orchestrate 4 specialized agents to review a plan through parallel analysis and iterative scoring until consensus.

## Agent Definitions

Read these files before starting the review loop. Inline their full content (after the YAML frontmatter) into each Agent() prompt:

| Role | File | Model | Phase |
|------|------|-------|-------|
| Architect | `~/.claude/agents/plan-architect.md` | sonnet | Phase 1 (parallel) |
| Skeptic | `~/.claude/agents/plan-skeptic.md` | opus | Phase 1 (parallel) |
| Pragmatist | `~/.claude/agents/plan-pragmatist.md` | sonnet | Phase 1 (parallel) |
| Synthesizer | `~/.claude/agents/plan-synthesizer.md` | opus | Phase 2 (sequential) |

## Input Handling

Parse `$ARGUMENTS`:
- If argument contains `/` or ends with `.md` → treat as file path, read the file
- Otherwise → treat as text input:
  1. Generate a short kebab-case topic slug from the text
  2. Save to `docs/plans/YYYY-MM-DD-<topic>-plan.md`
  3. Inform user: "Saved plan to docs/plans/..."

Store the plan text in a variable for the loop.

## Orchestration Loop

```
MAX_ITERATIONS = 5
iteration = 1
previous_feedback = ""

WHILE iteration <= MAX_ITERATIONS:

  1. Show: "## Review Iteration {iteration}/{MAX_ITERATIONS}"

  2. PHASE 1 — PARALLEL ANALYSIS
     Read all 4 agent .md files from ~/.claude/agents/
     Launch 3 Agent() calls in a SINGLE message (parallel):
       - Agent(subagent_type="general-purpose", model="sonnet",
               prompt="{architect_prompt}\n\n## PLAN TO REVIEW\n\n{plan}\n\n## PREVIOUS FEEDBACK\n\n{previous_feedback}")
       - Agent(subagent_type="general-purpose", model="opus",
               prompt="{skeptic_prompt}\n\n## PLAN TO REVIEW\n\n{plan}\n\n## PREVIOUS FEEDBACK\n\n{previous_feedback}")
       - Agent(subagent_type="general-purpose", model="sonnet",
               prompt="{pragmatist_prompt}\n\n## PLAN TO REVIEW\n\n{plan}\n\n## PREVIOUS FEEDBACK\n\n{previous_feedback}")

  3. Parse JSON from each agent's response
     Show per-agent summary table:
       | Agent      | Score | Key Finding |
       |------------|-------|-------------|
       | Architect  | XX/25 | ...         |
       | Skeptic    | XX/25 | ...         |
       | Pragmatist | XX/25 | ...         |

  4. PHASE 2 — SYNTHESIS
     Launch 1 Agent() call:
       - Agent(subagent_type="general-purpose", model="opus",
               prompt="{synthesizer_prompt}\n\n## PLAN\n\n{plan}\n\n## ARCHITECT REPORT\n\n{architect_json}\n\n## SKEPTIC REPORT\n\n{skeptic_json}\n\n## PRAGMATIST REPORT\n\n{pragmatist_json}")

  5. Parse synthesizer JSON response
     Show verdict:
       ### Synthesizer Verdict: {verdict} ({total_score}/25)
       {dimension scores}
       {revision_guidance if REVISE}

  6. ROUTE on verdict:
     - APPROVED (>= 20): Show final report, STOP
     - REVISE (15-19):
         previous_feedback = all 4 reports concatenated
         iteration += 1
         CONTINUE loop
     - REJECT (< 15):
         Ask user via AskUserQuestion:
           "Plan scored {score}/25 (REJECT). Options?"
           - "Show me the issues and I'll rework the plan"
           - "Try one more iteration anyway"
           - "Stop review"
         Handle user choice accordingly

END WHILE

IF iteration > MAX_ITERATIONS:
  Show: "Reached maximum {MAX_ITERATIONS} iterations without APPROVED."
  Show best score achieved and remaining issues.
```

## JSON Parsing

Agent responses are text. Extract the JSON object:
- Look for the first `{` and last `}` in the response
- Parse the substring as JSON
- If parsing fails, show the raw response and note the parsing error

## Final Report Format (APPROVED)

```
## Plan Review: APPROVED ({score}/25)

**Iterations:** {N}
**Final Scores:** Completeness {X} | Feasibility {X} | Architecture {X} | Risk {X} | Clarity {X}

### Key Findings
{bullet list from synthesizer.key_findings}

### Remaining Considerations
{any minor-severity items from all agents}

### Recommended Next Steps
{synthesizer.revision_guidance if any minor items, or "Plan is ready for implementation"}
```

## Error Handling

- If an agent returns non-JSON: show raw output, use score 0, continue
- If all 3 Phase 1 agents fail: stop and report the error
- If Synthesizer fails: use average of Phase 1 scores as total, ask user to proceed

## IMPORTANT

- ALWAYS launch Phase 1 agents in a SINGLE message (3 parallel Agent calls)
- NEVER modify the plan — only analyze it
- NEVER skip the Synthesizer — it's the only agent that issues verdicts
- Context isolation is critical — agents must NOT explore the codebase
