---
name: se-doc-review
description: Review requirements, plans, or specs — runs the compound-engineering persona review PLUS two full independent runs of the same review by external agents (claude + opencode, each with its own persona subagents) in parallel via a smithers harness, then synthesizes all three envelopes. Use when the user wants to improve an existing planning document.
argument-hint: "[mode:headless] [path/to/document.md]"
---

# Document Review (wrapper: local persona review + external reviews via smithers)

Wrapper over `compound-engineering:ce-doc-review`. Runs the plugin review locally AND has two external agents (claude and opencode) each execute the **same plugin workflow** end-to-end — dispatching their own persona subagents on their own model family — then synthesizes the three result envelopes.

All external orchestration (staging, parallel CLI launches, timeouts, budget caps, envelope collection) is **code**, not prose: the smithers workflow at `~/.claude/.smithers/workflows/se-doc-review.tsx` (pinned `smithers-orchestrator`, see `~/.claude/.smithers/package.json`). Do not re-implement any of it in instructions — launch it and read its outputs.

Argument contract is identical to the plugin skill: tokens starting with `mode:` are flags; the remaining token (if any) is the document path. `mode:headless` is passed through.

**Cost note:** three multi-agent reviews (up to 7 persona subagents each; opencode on GPT-5.5). A normal external claude leg bills ~$5-6; its `maxBudgetUsd: 15` is a runaway circuit breaker, not a cost target, and re-arms on retry — effective ceiling ≈ attempts × cap. Actual claude spend appears as `total_cost_usd` in the harness log. Expect ~5-10 minutes and ~3x the token cost of a plain review. For a quick pass, use `compound-engineering:ce-doc-review` directly.

## Recursion guard (read first)

If the current prompt contains the marker `[ce-doc-review-external-consult]`, you ARE one of the external consults. Execute only the plugin workflow on the document you were given and return its envelope. Never launch the harness or external consults from inside a consult. (The harness embeds this marker in every consult prompt.)

## Phase 1: Resolve the document

- Path provided → use it (make it absolute).
- No path, interactive → ask which document, or find the most recent in `docs/brainstorms/` / `docs/plans/` via Glob.
- No path, headless → output `Review failed: headless mode requires a document path. Re-invoke with: Skill("se-doc-review", "mode:headless <path>")` and stop. Do not launch anything.

## Phase 2: Launch the external harness (background, FIRST)

One background Bash task (`run_in_background: true`), launched **before** the local plugin review so all three reviews run concurrently:

```bash
cd ~/.claude/.smithers && \
DOC_REVIEW_REPO="<abs repo root>" ./node_modules/.bin/smithers up workflows/se-doc-review.tsx \
  --input '{"docPath":"<abs document path>"}'
```

- Launch from `~/.claude/.smithers` — smithers drops its state there, outside the target repo. Runtime state is ignored by that directory's `.gitignore`.
- Staging goes to `/tmp/ce-doc-review/run-<ts>/` (a read-only doc copy + plugin-skill bundle); opencode reads it via the `permission.external_directory` allow in `~/.config/opencode/opencode.json`. If opencode starts failing with rejected reads, check that config before touching the workflow. External agents are report-only — they change no files; their would-be safe_auto fixes come back as findings inside the envelope.
- The run's final output prints `stageDir`, `pluginVersion` (the compound-engineering version the external reviews ran against — cite it in Coverage), `claudeStatus` / `opencodeStatus` (`ok` | `failed`), and an envelope path per surviving agent.
- Add `"smoke":true` to the input for a cheap wiring test (no real review).

**Error handling:** a failed agent does NOT fail the run — each leg is wrapped in an error boundary, so the run finishes with that leg's status `failed` and the surviving envelope still collected. Use what exists, note the failure in the final Coverage section, and diagnose later with `./node_modules/.bin/smithers logs <runId>` / `smithers chat <runId>` from `~/.claude/.smithers`. Actual claude cost: `total_cost_usd` lines in the background task output.

## Phase 3: Run the local plugin review

Invoke the Skill tool with skill `compound-engineering:ce-doc-review` and the **original arguments unchanged** (including `mode:headless` when present, and the resolved original document path — local safe_auto fixes land on the real document). Let it run its full flow.

Never invoke bare `se-doc-review` from here — that is this wrapper.

## Phase 4: Collect external envelopes

After the local review returns, wait for the background harness task. Cap the wait at ~25 min — the harness's own worst case is 2 attempts × 10-min per-attempt timeout per leg, so it always exits before that; past the cap, treat the harness as hung and its envelopes as failed. Then read the envelope path(s) the final output block reported (an agent with status `failed` has none — that's expected, not an error).

## Phase 5: Synthesize the three envelopes

All three results share the envelope structure (Applied / Proposed fixes / Decisions / FYI / Residual). Merge by section + issue substance:

1. **Consensus** — the same finding in 2+ envelopes. Report once with all sources; agreement across model families is the strongest signal in this review. If the local review already applied or proposed it, mark as confirmed rather than re-opening.
2. **Unique** — findings only one review produced. These are the payload of running three: name which review caught it and why the others plausibly missed it.
3. **Contradictions** — reviews disagree on substance, or the local review's applied fix conflicts with an external finding (externals apply nothing; their safe_auto candidates are findings in the envelope). Surface explicitly with both positions; do not silently pick a side.
4. **Fix divergence** — same finding, materially different suggested_fix. Present the strongest fix with attribution; note the alternatives in one line.

Present as:

```
## Cross-review synthesis
Coverage: local personas: <list>; external claude: <ok | failed>; external opencode: <ok | failed>
### Consensus (N)
### Unique findings (M) — by source
### Contradictions / fix divergence (K)
```

**Delivery by mode:**

- **Interactive:** print the synthesis, then for unresolved Consensus/Unique/Contradiction findings offer the standard routing (walk through / apply best judgment / append to Open Questions / report only) via AskUserQuestion (preload with `ToolSearch select:AskUserQuestion`).
- **Headless:** append the synthesis to the local review's envelope and return the combined text to the caller. No questions — the caller (e.g. se-plan) decides.

`/tmp/ce-doc-review/run-*` dirs are ephemeral tmp — leave them; no cleanup inside the repo is ever needed.
