---
name: se-code-review
description: Code review, three independent runs synthesized — the local plugin review plus external claude and opencode. Use before a PR or when asked to review code; for a quick single-pass review use compound-engineering:ce-code-review.
argument-hint: "[mode:agent] [blank to review current branch, or PR link / base:<ref> / plan:<path> / depth: / grouping:]"
---

# Code Review (wrapper: local persona review + external reviews via smithers)

Wrapper over `compound-engineering:ce-code-review`. Runs the plugin review locally AND has two external agents (claude and opencode) each execute the **same plugin workflow** in `mode:agent` on a **frozen snapshot** of the checkout — dispatching their own reviewer subagents on their own model family — then synthesizes the three result reports.

All external orchestration (snapshotting, staging, parallel CLI launches, timeouts, budget caps, report collection) is **code**, not prose: the smithers workflow at `~/.claude/.smithers/workflows/se-code-review.tsx`. Do not re-implement any of it in instructions — launch it and read its outputs. Harness mechanics shared with `/se-doc-review` and `/se-simplify` — launching, the secret gate, staging, error boundaries, the wait cap, diagnostics: read `~/.claude/shared/se-harness.md`.

Argument contract is identical to the plugin skill: `mode:` / `base:` / `plan:` / `depth:` / `grouping:` tokens plus an optional PR number/URL/branch target. Everything is passed through to the local review unchanged.

**Cost note:** three multi-persona reviews (up to ~9 reviewer subagents each; opencode on GPT-5.5). A normal external claude leg bills ~$5-8; a big diff (4800+ lines) bills ~$17+. The claude leg runs `retries={0}` because budget exhaustion is deterministic for a given diff — a retry burns the cap again on the same failure. Expect ~10-20 minutes and ~3x the token cost of a plain review. For a quick pass, use `compound-engineering:ce-code-review` directly (its quick-review short-circuit also stays available there).

## Recursion guard (read first)

If the current prompt contains the marker `[ce-code-review-external-consult]`, you ARE one of the external consults. Execute only the plugin workflow in mode:agent on the checkout you were given and return its JSON report. Never launch the harness or external consults from inside a consult. (The harness embeds this marker in every consult prompt.)

## Phase 1: Resolve the target

- Parse the arguments exactly like the plugin does: strip recognized tokens; the remainder (if any) is the PR number/URL/branch.
- Build the harness `target` string: the original arguments **minus all `mode:` tokens** (externals always run `mode:agent`). Empty string = review the current branch against an auto-detected base — the harness computes and freezes the merge-base itself.
- Conflicting arguments (per the plugin's rules) → don't launch anything; report the same one-line failure the plugin would.

## Phase 2: Launch the external harness (background, FIRST)

One background Bash task (`run_in_background: true`), launched **before** the local plugin review so all three reviews run concurrently:

```bash
cd ~/.claude/.smithers && \
CODE_REVIEW_REPO="<abs repo root>" ./node_modules/.bin/smithers up workflows/se-code-review.tsx \
  --input '{"target":"<target string, may be empty>"}'
```

- The harness **freezes the review target** before anything else: `git stash create` captures dirty tracked state (untracked files are excluded, matching the plugin's own default scope) and a detached `git worktree` under `/tmp/ce-code-review/run-<ts>/repo` checks it out. External agents review that snapshot, so the local review applying fixes and committing mid-run cannot move the diff under them.
- **Secret gate range:** merge-base with the base branch → the stash snapshot, dirty tree included. A secret already committed on the base branch is inside the snapshot and is not scanned.
- The run's final output prints `stageDir`, `pluginVersion` (the compound-engineering version the external reviews ran against — cite it in Coverage), `snapshotSha`, `consultTarget`, `claudeStatus` / `opencodeStatus` (`ok` | `failed`), and a report path per surviving agent.

## Phase 3: Run the local plugin review

Invoke the Skill tool with skill `compound-engineering:ce-code-review` and the **original arguments unchanged** (including any `mode:` token — local interactive mode may apply fixes; that's its contract, and the snapshot isolates the externals from it). Let it run its full flow.

Never invoke bare `se-code-review` from here — that is this wrapper.

## Phase 4: Collect external reports

After the local review returns, wait for the background harness task (wait cap: se-harness → Waiting for the harness). Then read the report path(s) the final output block reported (an agent with status `failed` has none — that's expected, not an error). Each report is the plugin's `mode:agent` JSON (`status`, `verdict`, `findings[]`, `actionable_findings[]`, …); a report with `"status": "failed"` / `"degraded"` / `"skipped"` counts as that agent's honest result, not a harness failure.

## Phase 5: Synthesize the three reports

All three results share the finding structure (severity P0-P3, file/line, `autofix_class`, `suggested_fix`). Merge by file/line proximity + issue substance:

1. **Consensus** — the same finding in 2+ reports. Report once with all sources; agreement across model families is the strongest signal in this review. If the local review already applied or reported it, mark as confirmed rather than re-opening. On severity disagreement within a consensus finding, keep the highest severity and note the spread.
2. **Unique** — findings only one review produced. These are the payload of running three: name which review caught it and why the others plausibly missed it.
3. **Contradictions** — reviews disagree on substance (one calls it a bug, another calls it intended), or the local review's applied fix conflicts with an external finding. Surface explicitly with both positions; do not silently pick a side.
4. **Fix divergence** — same finding, materially different `suggested_fix`. Present the strongest fix with attribution; note the alternatives in one line.

Verdict: take the most conservative of the three verdicts ("Not ready" > "Ready with fixes" > "Ready to merge") unless the stricter verdict rests solely on a finding the synthesis rejected — then say so explicitly.

Present as:

```
## Cross-review synthesis
Coverage: local reviewers: <list>; external claude: <ok | failed>; external opencode: <ok | failed>; plugin <version>
Verdict: <merged verdict> (local: X / claude: Y / opencode: Z)
### Consensus (N)
### Unique findings (M) — by source
### Contradictions / fix divergence (K)
```

**Delivery by mode:**

- **Interactive (default):** print the synthesis after the local review's report, then for unresolved Consensus/Unique/Contradiction findings offer the standard routing (walk through / apply best judgment / report only) via AskUserQuestion (preload with `ToolSearch select:AskUserQuestion`).
- **`mode:agent`:** return the local review's JSON with one added top-level field `cross_review`: `{ "coverage": {...}, "verdict_by_source": {...}, "consensus": [...], "unique": [...], "contradictions": [...] }` (findings referenced by their stable `#` from the local report where they exist there, inline objects otherwise). No questions — the caller decides.

