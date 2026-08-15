---
name: se-work
description: Execute an already-reviewed implementation-ready plan via the durable se-pipeline (smithers) — work → simplify → verify-code → branch/PR, WITHOUT plan-review, plus secret-scan gates, approval pauses, and a cost summary. Use when the user says "запусти пайплайн", "run the pipeline", "se-work по плану X", or wants a prepared plan executed end-to-end durably. For a plan that still needs plan-review first, use `se-review-and-work`.
argument-hint: "[plan-path] [until:pr] [validate-cmd:'<cmd>']"
---

# Execute a plan via se-pipeline, no plan-review (wrapper over the `se` CLI)

Runs the durable pipeline **without** the verify-doc plan-review stage: `work → simplify → verify-code → branch/PR`. Use it when the plan is already prepared and human-reviewed. To run the SAME pipeline WITH plan-review first (`verify-doc → work → simplify → verify-code`), use the sibling command **`se-review-and-work`** — it is this command with plan-review turned on. The user picks by command name; neither skill asks you to type a flag.

The **simplify** stage runs in BOTH commands — it is new relative to the old `se-work`, always present, and autonomously run-or-skipped by its own right-sizing gate (no flag). It tidies the work-stage output (two cross-model report legs → one verified apply) before code review sees it.

All orchestration is **code**, not prose: the `se` CLI (`~/.claude/.smithers/bin/se`, on PATH as `se`) wrapping the smithers workflow `~/.claude/.smithers/workflows/se-pipeline.tsx`. Do not re-implement stages, gates, or resume logic in instructions — launch and observe. Troubleshooting source of truth: `docs/se-pipeline.md` in the my-mac-setup repo.

Argument contract: an optional plan path; `until:pr` maps to `--until=pr`; `validate-cmd:'<cmd>'` maps to `--validate-cmd` (override only — omitted, the workflow derives the command from the plan's Verification Contract). This command NEVER passes `--doc-review` (that is what `se-review-and-work` is for).

## Phase 1 — resolve and preflight

- Plan: explicit path argument, else the freshest `docs/plans/*.md` with `artifact_readiness: implementation-ready`. When not explicit, confirm the pick with the user before launching.
- `artifact_readiness: requirements-only` → stop; that plan needs `/se-plan` enrichment first.
- No Verification Contract in the plan → gate-0 hard-errors. Flag it before launch; pass `--validate-cmd` only if the user supplied an override.
- Launch from the **target repo root** — the cwd becomes `PIPELINE_REPO` / `DOC_REVIEW_REPO`.
- Check `se list` first: an already-running run on the same repo means observe it, not double-launch.

## Phase 2 — launch (detached)

```bash
cd <repo-root> && se pipeline <plan-path> [--until=pr] [--validate-cmd '<cmd>']
```

- Default stop stage is `branch`. `--until=pr` opens a PR — outward-facing; use only when the user asked for a PR.
- Detached (the default) prints the runId and returns. Report the runId to the user immediately, with the observe commands (`se logs <runId>`, `se show <runId>`).
- Never use `--attach` in an agent session: Ctrl-C/SIGINT there CANCELS the run.

## Phase 3 — monitor

Poll with a background Bash task (`run_in_background: true`) — foreground sleep loops are blocked in Claude Code:

```bash
while :; do
  st=$(se show <runId> --json | jq -r '.run.status // empty')
  case $st in running|pending|"") sleep 30 ;; *) echo "$st"; break ;; esac
done
```

While it runs, keep the session free for the user; report when the task re-invokes you.

- **`waiting-approval`** — a gate paused the run (doc-review not green, work gate red, code-review findings). Gather why: `se show <runId>`, which prints the pending request under `DECISION REQUIRED` — its title, and the gate's reasons. **Never read the check marks in `se logs` as verdicts**: the engine marks a node that finished, so a gate that decided *failed* carries the same ✓ as a green one; the `GATE <stage>: FAILED` block in the log and the request title in `se show` are the verdict. Approve does NOT always mean continue — at a red work gate it buys ONE more paid attempt of that stage, and after a second failure it stops the run with a report. Present the pause as a decision brief, not a raw gate dump: what this gate checks in plain words, what failed and why (the title verbatim plus the reasons), what approve / deny / abort each does to the run — approve = one more paid attempt of the stage, deny = stop with a report, abort = kill the run — and your recommendation. Then ask via AskUserQuestion (preload with `ToolSearch select:AskUserQuestion`); each option description must carry its consequence, so the user can decide without reading the log. Then `se approve <runId>` (or `deny`/`abort`), which records the decision and resumes the run itself — the owner process exits when a run parks, so a recorded decision moves nothing on its own. It declines to resume only when a live process already owns the run, and says so. If it ever leaves the run parked anyway, `se resume <runId>` continues it.
- **Killed / cancelled** — `se resume <runId>`. Force-resume waits out the dead owner's heartbeat (~30-45s); `se` prints the hint when that applies.
- Never edit files inside the run's worktree while the run is live.

## Phase 4 — report

`se show <runId>` → verdict | branch | tokens | ~USD | reportDir. Then:

- Read the reportDir envelopes (doc-review, code-review) and summarize their findings — not just the verdict word.
- `until=pr` → include the PR URL (in `se logs` / summary notes).
- Tokens are ground truth; USD is an estimate.
- Report the verdict as-is: `green` is done; `degraded`/`failed` gets surfaced with the reasons from the envelopes, never rounded up to "completed".
- The report turn carries no questions. If the envelopes leave decisions open, ask them after the report — one per turn, each as a self-contained decision brief (the thing in plain words, what is being decided, options with consequences, recommendation). Never a one-line "needs your decision" row with a ticket or PR number.

## Cost / time

`se-work` run ≈ work leg (opus) + simplify (two Sonnet-class report legs + one apply + verify, unless the right-sizing gate skips it) + verify-code (claude + opencode). Plan-review is NOT run here — that is the `se-review-and-work` addition. Simplify has strictly more stages than nothing, so it is a real time/cost add over the old flag-less `se-work`, not neutral; a skipped simplify (empty/doc-only/borderline diff) costs almost nothing. Expect ~30-75 min wall clock. Cost lands in the `se list` summary table after the run. For a quick non-durable execution of a small plan, `compound-engineering:ce-work` in-session is cheaper.
