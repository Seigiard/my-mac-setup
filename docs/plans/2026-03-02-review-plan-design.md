# /review-plan Command Design

Multi-agent plan review with iterative debate and consensus scoring.

## Problem

Plans created by a single Claude session lack adversarial scrutiny. Unverified assumptions, architectural blind spots, and impractical steps go unchallenged.

## Solution

A `/review-plan` command that spawns 4 specialized agents to independently analyze a plan, then synthesize findings through iterative scoring until consensus (or max iterations).

## Architecture

### File Structure

```
home/private_dot_claude/
├── skills/review-plan/SKILL.md      # Orchestration protocol
├── commands/review-plan.md           # Entry point
└── agents/
    ├── plan-architect.md             # Structure/patterns reviewer (sonnet)
    ├── plan-skeptic.md               # Assumption challenger (opus)
    ├── plan-pragmatist.md            # Feasibility assessor (sonnet)
    └── plan-synthesizer.md           # Judge/consensus scorer (opus)
```

### Input Handling

The command accepts flexible input:
- **File path:** `/review-plan path/to/plan.md` — reads and reviews the file
- **Text:** `/review-plan "my plan text..."` — saves to `docs/plans/YYYY-MM-DD-<topic>-plan.md`, then reviews
- **Auto-detect:** if argument looks like a file path (contains `/` or ends with `.md`), treat as file; otherwise treat as text

When input is text (not a file), the plan is saved to `docs/plans/` before review begins, so there's always a file artifact.

## Agent Roles

### Architect (model: sonnet)

Focus: structure, scalability, patterns, component dependencies, separation of concerns.

Output format:
```json
{
  "findings": [{"area": "...", "severity": "critical|major|minor", "description": "...", "suggestion": "..."}],
  "score": 0-25,
  "summary": "..."
}
```

### Skeptic (model: opus)

Focus: unverified assumptions, weak points, edge cases, "mirages" (false claims about APIs, libraries, capabilities).

Output format:
```json
{
  "challenges": [{"claim": "...", "verdict": "VERIFIED|UNVERIFIED|MIRAGE", "evidence": "...", "impact": "..."}],
  "score": 0-25,
  "summary": "..."
}
```

### Pragmatist (model: sonnet)

Focus: implementation feasibility, complexity, dependencies, time-to-value, simpler alternatives.

Output format:
```json
{
  "assessments": [{"area": "...", "feasibility": "high|medium|low", "risk": "...", "suggestion": "..."}],
  "score": 0-25,
  "summary": "..."
}
```

### Synthesizer / Judge (model: opus)

Aggregates all three reports. Scores plan across 5 dimensions (5 points each, 25 max):

1. **Completeness** — all aspects covered?
2. **Feasibility** — realistically buildable?
3. **Architecture** — structurally sound?
4. **Risk mitigation** — risks identified and addressed?
5. **Clarity** — unambiguous, concrete steps?

Verdict:
- **APPROVED** (score >= 20): plan is ready
- **REVISE** (score 15-19): specific improvements needed, iterate
- **REJECT** (score < 15): fundamental issues, ask user

Output format:
```json
{
  "dimensions": [{"name": "...", "score": 0-5, "reasoning": "..."}],
  "total_score": 0-25,
  "verdict": "APPROVED|REVISE|REJECT",
  "revision_guidance": "...",
  "summary": "..."
}
```

## Iteration Protocol

```
Iteration N (max 5):

  Phase 1: PARALLEL ANALYSIS
    3 Agent() calls in a single message:
    - Agent(general-purpose, model=sonnet) with plan-architect prompt
    - Agent(general-purpose, model=opus) with plan-skeptic prompt
    - Agent(general-purpose, model=sonnet) with plan-pragmatist prompt
    Each receives: plan + all feedback from iteration N-1 (if any)

  Phase 2: SYNTHESIS
    Agent(general-purpose, model=opus) with plan-synthesizer prompt
    Receives: plan + all 3 Phase 1 reports
    Returns: score + verdict

  Routing:
    APPROVED (>=20) → final report to user, stop
    REVISE (15-19)  → all reports become feedback for iteration N+1
    REJECT (<15)    → ask user: rework plan or stop?

  Max iterations reached → show best result + warning
```

### Context Isolation

Every agent prompt starts with:
```
CONTEXT ISOLATION: Focus ONLY on analyzing the plan below.
Do NOT explore or modify the codebase. Do NOT ask clarifying questions.
Produce the requested analysis.
```

### Inter-iteration Context

On REVISE, iteration N+1 agents receive:
- The original plan (unchanged)
- All 4 reports from iteration N (architect, skeptic, pragmatist, synthesizer)
- The `revision_guidance` field from Synthesizer

## Output Format

### Per-iteration progress:

```
## Review Iteration 2/5

| Agent      | Score | Key Finding                     |
|------------|-------|---------------------------------|
| Architect  | 21/25 | Missing error handling strategy  |
| Skeptic    | 17/25 | 2 unverified assumptions found   |
| Pragmatist | 19/25 | Step 3 has hidden complexity     |

### Synthesizer Verdict: REVISE (19/25)
Completeness 4 | Feasibility 3 | Architecture 4 | Risk 4 | Clarity 4

Guidance: Address unverified assumptions in steps 2 and 5, add error handling section.

Starting iteration 3...
```

### Final report (APPROVED):

```
## Plan Review: APPROVED (22/25)

Iterations: 3
Final Scores: Completeness 5 | Feasibility 4 | Architecture 5 | Risk 4 | Clarity 4

### Key Findings Addressed
...
### Remaining Considerations (minor)
...
### Recommended Next Steps
...
```

## Decisions Made

- **No Stop hook** — all orchestration in SKILL.md, simpler to debug
- **No external scripts** — pure markdown plugin, zero infrastructure
- **Opus for Skeptic + Synthesizer** — critical roles need strongest model
- **Sonnet for Architect + Pragmatist** — good enough for structured analysis, saves cost
- **JSON output from agents** — structured for reliable parsing by orchestrator
- **Max 5 iterations** — prevents runaway loops while allowing thorough review
- **Context isolation** — prevents agents from exploring codebase instead of analyzing plan
- **Text input saved to docs/plans/** — always creates a file artifact for traceability
