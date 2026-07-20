---
name: se-work
description: Execute an implementation-ready plan via the durable se-pipeline (smithers) — verify-doc → work → verify-code → branch/PR, with secret-scan gates, approval pauses, and a cost summary. Use when the user says "запусти пайплайн", "run the pipeline", "se-work по плану X", or wants a plan executed end-to-end durably instead of an in-session ce-work.
argument-hint: "[plan-path] [until:pr] [validate-cmd:'<cmd>']"
---

# Execute a plan via se-pipeline (wrapper over the `se` CLI)

All orchestration is **code**, not prose: the `se` CLI (`~/.claude/.smithers/bin/se`, on PATH as `se`) wrapping the smithers workflow `~/.claude/.smithers/workflows/se-pipeline.tsx`. Do not re-implement stages, gates, or resume logic in instructions — launch and observe. Troubleshooting source of truth: `docs/se-pipeline.md` in the my-mac-setup repo.

Argument contract: an optional plan path; `until:pr` maps to `--until=pr`; `validate-cmd:'<cmd>'` maps to `--validate-cmd` (override only — omitted, the workflow derives the command from the plan's Verification Contract).

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

- **`waiting-approval`** — a gate paused the run (doc-review not green, work gate red, code-review findings). Gather why: `se show <runId>` + tail of `se logs <runId>`. Present situation/reason/legal actions to the user and ask approve / deny / abort via AskUserQuestion (preload with `ToolSearch select:AskUserQuestion`). Then `se approve <runId>` (or `deny`/`abort`). If `se show` still reports the run parked after approve — the owner process already exited — `se resume <runId>` continues it.
- **Killed / cancelled** — `se resume <runId>`. Force-resume waits out the dead owner's heartbeat (~30-45s); `se` prints the hint when that applies.
- Never edit files inside the run's worktree while the run is live.

## Phase 4 — report

`se show <runId>` → verdict | branch | tokens | ~USD | reportDir. Then:

- Read the reportDir envelopes (doc-review, code-review) and summarize their findings — not just the verdict word.
- `until=pr` → include the PR URL (in `se logs` / summary notes).
- Tokens are ground truth; USD is an estimate.
- Report the verdict as-is: `green` is done; `degraded`/`failed` gets surfaced with the reasons from the envelopes, never rounded up to "completed".

## Cost / time

Full run ≈ verify-doc (two external review envelopes: claude + opencode) + work leg (opus) + verify-code; expect 30-90 min wall clock. Cost lands in the `se list` summary table after the run. For a quick non-durable execution of a small plan, `compound-engineering:ce-work` in-session is cheaper.
