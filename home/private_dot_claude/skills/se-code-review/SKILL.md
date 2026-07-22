---
name: se-code-review
description: Structured code review — runs the compound-engineering multi-persona review PLUS two full independent runs of the same review by external agents (claude + opencode, each with its own reviewer subagents) in parallel via a smithers harness, then synthesizes all three reports. Use before PRs or when asked for a code review.
argument-hint: "[mode:agent] [blank to review current branch, or PR link / base:<ref> / plan:<path> / depth: / grouping:]"
---

# Code Review (wrapper: local persona review + external reviews via smithers)

Wrapper over `compound-engineering:ce-code-review`. Runs the plugin review locally AND has two external agents (claude and opencode) each execute the **same plugin workflow** in `mode:agent` on a **frozen snapshot** of the checkout — dispatching their own reviewer subagents on their own model family — then synthesizes the three result reports.

All external orchestration (snapshotting, staging, parallel CLI launches, timeouts, budget caps, report collection) is **code**, not prose: the smithers workflow at `~/.claude/.smithers/workflows/se-code-review.tsx` (pinned `smithers-orchestrator`, see `~/.claude/.smithers/package.json`). Do not re-implement any of it in instructions — launch it and read its outputs.

Argument contract is identical to the plugin skill: `mode:` / `base:` / `plan:` / `depth:` / `grouping:` tokens plus an optional PR number/URL/branch target. Everything is passed through to the local review unchanged.

**Cost note:** three multi-persona reviews (up to ~9 reviewer subagents each; opencode on GPT-5.5). A normal external claude leg bills ~$5-8; its `maxBudgetUsd: 15` is a runaway circuit breaker, not a cost target, and re-arms on retry — effective ceiling ≈ attempts × cap. Actual claude spend appears as `total_cost_usd` in the harness log. Expect ~10-20 minutes and ~3x the token cost of a plain review. For a quick pass, use `compound-engineering:ce-code-review` directly (its quick-review short-circuit also stays available there).

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

- Launch from `~/.claude/.smithers` — smithers drops its state there, outside the target repo. Runtime state is ignored by that directory's `.gitignore`.
- The harness **freezes the review target** before anything else: `git stash create` captures dirty tracked state (untracked files are excluded, matching the plugin's own default scope) and a detached `git worktree` under `/tmp/ce-code-review/run-<ts>/repo` checks it out. External agents review that snapshot, so the local review applying fixes and committing mid-run cannot move the diff under them. The snapshot worktree is removed by the harness's final step; if a crashed run leaves one behind, `git -C <repo> worktree prune` from the main checkout cleans the metadata.
- Staging (snapshot + plugin-skill bundle) lives under `/tmp/ce-code-review/`; opencode reads it via the `permission.external_directory` allow in `~/.config/opencode/opencode.json`. If opencode starts failing with rejected reads, check that config before touching the workflow.
- The run's final output prints `stageDir`, `pluginVersion` (the compound-engineering version the external reviews ran against — cite it in Coverage), `snapshotSha`, `consultTarget`, `claudeStatus` / `opencodeStatus` (`ok` | `failed`), and a report path per surviving agent.
- Add `"smoke":true` to the input for a cheap wiring test (no real review).

**Error handling:** a failed agent does NOT fail the run — each leg is wrapped in an error boundary, so the run finishes with that leg's status `failed` and the surviving report still collected. Use what exists, note the failure in the final Coverage section, and diagnose later with `./node_modules/.bin/smithers logs <runId>` / `smithers chat <runId>` from `~/.claude/.smithers`. Actual claude cost: `total_cost_usd` lines in the background task output.

## Phase 3: Run the local plugin review

Invoke the Skill tool with skill `compound-engineering:ce-code-review` and the **original arguments unchanged** (including any `mode:` token — local interactive mode may apply fixes; that's its contract, and the snapshot isolates the externals from it). Let it run its full flow.

Never invoke bare `se-code-review` from here — that is this wrapper.

## Phase 4: Collect external reports

After the local review returns, wait for the background harness task. Cap the wait at ~55 min — the harness's own worst case is 2 attempts × 25-min per-attempt timeout on the claude leg, plus smithers reap lag on a timed-out attempt (observed +13 min on run 46dec4cf); past the cap, treat the harness as hung and its reports as failed. Then read the report path(s) the final output block reported (an agent with status `failed` has none — that's expected, not an error). Each report is the plugin's `mode:agent` JSON (`status`, `verdict`, `findings[]`, `actionable_findings[]`, …); a report with `"status": "failed"` / `"degraded"` / `"skipped"` counts as that agent's honest result, not a harness failure.

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

`/tmp/ce-code-review/run-*` dirs are ephemeral tmp — leave them; no cleanup inside the repo is ever needed (the harness removes its git worktree itself).
