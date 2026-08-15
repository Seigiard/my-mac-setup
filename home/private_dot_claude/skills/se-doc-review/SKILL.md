---
name: se-doc-review
description: Review a plan, spec, or requirements doc — three independent runs synthesized: the local plugin review plus external claude and opencode. Use to improve an existing planning document; se-plan invokes it headless.
argument-hint: "[mode:headless] [path/to/document.md]"
---

# Document Review (wrapper: local persona review + external reviews via smithers)

Wrapper over `compound-engineering:ce-doc-review`. Runs the plugin review locally AND has two external agents (claude and opencode) each execute the **same plugin workflow** end-to-end — dispatching their own persona subagents on their own model family — then synthesizes the three result envelopes.

All external orchestration (staging, parallel CLI launches, timeouts, budget caps, envelope collection) is **code**, not prose: the smithers workflow at `~/.claude/.smithers/workflows/se-doc-review.tsx`. Do not re-implement any of it in instructions — launch it and read its outputs. Harness mechanics shared with `/se-code-review` and `/se-simplify` — launching, the secret gate, staging, error boundaries, the wait cap, diagnostics: read `~/.claude/shared/se-harness.md`.

Argument contract is identical to the plugin skill: tokens starting with `mode:` are flags; the remaining token (if any) is the document path. `mode:headless` is passed through.

**Cost note:** three multi-agent reviews (up to 7 persona subagents each; opencode on GPT-5.5). A normal external claude leg bills ~$5-6; its budget cap re-arms on retry, so the effective ceiling is attempts × cap. Expect ~10-20 minutes (the claude leg's full plugin workflow runs ~12-17 min cold) and ~3x the token cost of a plain review. For a quick pass, use `compound-engineering:ce-doc-review` directly.

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

- **Secret gate range:** the document itself — a credential pasted into a plan is the whole payload here. The repo is not scanned on this path; it is read-only context for the legs.
- External agents are report-only — they change no files; their would-be safe_auto fixes come back as findings inside the envelope.
- The run's final output prints `stageDir`, `pluginVersion` (the compound-engineering version the external reviews ran against — cite it in Coverage), `claudeStatus` / `opencodeStatus` (`ok` | `failed`), and an envelope path per surviving agent.

## Phase 3: Run the local plugin review

Invoke the Skill tool with skill `compound-engineering:ce-doc-review` and the **original arguments unchanged** (including `mode:headless` when present, and the resolved original document path — local safe_auto fixes land on the real document). Let it run its full flow.

Never invoke bare `se-doc-review` from here — that is this wrapper.

## Phase 4: Collect external envelopes

After the local review returns, wait for the background harness task (wait cap: se-harness → Waiting for the harness). Then read the envelope path(s) the final output block reported (an agent with status `failed` has none — that's expected, not an error).

## Phase 5: Synthesize the three envelopes

All three results share the envelope structure (Applied / Proposed fixes / Decisions / FYI / Residual). Merge by section + issue substance:

Strip any `SEVERITY:` machine line from the envelopes before synthesizing — it is pipeline gate input (se-pipeline's `docReviewGate`), not review content, and must never appear in the human-facing synthesis.

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

- **Interactive:** print the synthesis, then for unresolved Consensus/Unique/Contradiction findings offer the standard routing (walk through / apply best judgment / append to Open Questions / report only) via AskUserQuestion (preload with `ToolSearch select:AskUserQuestion`). On walk through: one finding per turn, each a **decision brief** (`~/.claude/shared/decision-brief.md`), stripped of persona and envelope jargon. Wait for the answer before the next finding.
- **Headless:** append the synthesis to the local review's envelope and return the combined text to the caller. No questions — the caller (e.g. se-plan) decides.

