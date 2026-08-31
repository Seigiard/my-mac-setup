---
name: se-work
description: Execute a reviewed, implementation-ready plan on the durable se-pipeline (smithers) — work → simplify → verify-code → branch. Use when the user says "запусти пайплайн", "run the pipeline", "se-work по плану X", or wants a prepared plan executed end-to-end durably. A plan that still needs plan-review goes to `se-review-and-work`.
argument-hint: "[plan-path] [validate-cmd:'<cmd>'] [setup-cmd:'<cmd>']"
---

# Execute a plan via se-pipeline, no plan-review (wrapper over the `se` CLI)

Runs the durable pipeline **without** the verify-doc plan-review stage: `work → simplify → verify-code → branch/PR`. Use it when the plan is already prepared and human-reviewed. To run the SAME pipeline WITH plan-review first (`verify-doc → work → simplify → verify-code`), use the sibling command **`se-review-and-work`** — it is this command with plan-review turned on. The user picks by command name; neither skill asks you to type a flag.

The **simplify** stage runs in BOTH commands — it is new relative to the old `se-work`, always present, and autonomously run-or-skipped by its own right-sizing gate (no flag). It tidies the work-stage output (two cross-model report legs → one verified apply) before code review sees it.

All orchestration is **code**, not prose: the `se` CLI (`~/.claude/.smithers/bin/se`, on PATH as `se`) wrapping the smithers workflow `~/.claude/.smithers/workflows/se-pipeline.tsx`. Do not re-implement stages, gates, or resume logic in instructions — launch and observe. Troubleshooting source of truth: `~/Projects/my-mac-setup/docs/se-pipeline.md` — approve semantics per gate, resume quirks, validate-cmd rules, failure taxonomy. It is written in Russian. Launching from the target repo root means a bare `docs/se-pipeline.md` resolves to that repo, not this one; always use the absolute path.

Argument contract: an optional plan path; `validate-cmd:'<cmd>'` maps to `--validate-cmd` (override only — omitted, the workflow takes the command from the plan itself: the `validate_commands:` YAML list in its frontmatter, else its `Verification Contract` section); `setup-cmd:'<cmd>'` maps to `--setup-cmd`, a one-shot provisioning command run in the staged worktree before work (installs, workspace dist builds) — needed when the validate-cmd imports a sibling package's `dist/`. This command NEVER passes `--doc-review` (that is what `se-review-and-work` is for).

## Phase 1 — resolve and preflight

- Plan: explicit path argument, else the freshest `docs/plans/*.md` with `artifact_readiness: implementation-ready`. When not explicit, confirm the pick with the user before launching.
- `artifact_readiness: requirements-only` → stop; that plan needs the `se-plan` skill first.
- Neither a `validate_commands:` frontmatter list nor a `Verification Contract` section with a runnable command → gate-0 hard-errors, naming both shapes. Flag it before launch; pass `--validate-cmd` only if the user supplied an override. A declared list is used verbatim, so a declared mutating flag (`--write`, `--fix`) is refused there too — the work gate requires a clean worktree after the command runs.
- Launch from the **target repo root** — the cwd becomes `PIPELINE_REPO` / `DOC_REVIEW_REPO`.
- Check `se list` first: an already-running run on the same repo means observe it, not double-launch.

## Phase 2 — launch (detached)

```bash
cd <repo-root> && se pipeline <plan-path> [--validate-cmd '<cmd>'] [--setup-cmd '<cmd>']
```

- The run stops at the local branch `se/<plan>-<runid8>`. `--until=pr` is refused at gate-0 (`--until=pr is not implemented in the MVP`) — never pass it; open the PR by hand after the branch lands.
- Detached (the default) prints the runId and returns. Report the runId to the user immediately, with the observe commands (`se logs <runId>`, `se show <runId>`).
- Never use `--attach` in an agent session: Ctrl-C/SIGINT there CANCELS the run.

## Phase 3 — monitor

Read `~/.claude/shared/long-running-work.md`, then wait with the current client's supervised long-running mechanism. The monitor must survive the turn, make its first event observable, and wake the agent on the first non-running status; do not run a foreground sleep loop in the operator session. Use this monitor body:

```bash
while :; do
  st=$(se show <runId> --json | jq -r '.run.status // empty')
  case $st in running|pending|"") sleep 30 ;; *) echo "$st"; break ;; esac
done
```

While it runs, keep the session free for the user; report when the supervision mechanism re-invokes you or exposes the terminal event.

- **Killed / cancelled** — `se resume <runId>`. Force-resume waits out the dead owner's heartbeat (~30-45s); `se` prints the hint when that applies.
- Never edit files inside the run's worktree while the run is live.

### `waiting-approval` — a gate paused the run

Reached on a doc-review that is not green, a red work gate, or code-review findings.

- **Read the verdict, not the log.** A ✓ in `se logs` means the node finished — a gate that decided *failed* carries the same ✓ as a green one. The verdict is the `GATE <stage>: FAILED` block in the log and the request title under `DECISION REQUIRED` in `se show <runId>`.
- **Approve is not "continue."** At a red work gate it buys ONE more paid attempt of that stage; a second failure stops the run with a report. Per-gate approve semantics: `~/Projects/my-mac-setup/docs/se-pipeline.md`.
- **Present the pause as a decision brief** (`~/.claude/shared/decision-brief.md`): what this gate checks in plain words, the failure verbatim plus the gate's reasons, what approve / deny / abort each do to the run, your recommendation. Ask with the current platform's blocking question tool; each option description carries its consequence, so the user decides without reading the log.
- **Record it with `se approve <runId>`** (or `deny` / `abort`) — it resumes the run itself, because the owner process exits when a run parks and a recorded decision moves nothing on its own. It declines only when a live process already owns the run, and says so. Still parked → `se resume <runId>`.

## Phase 4 — report

`se show <runId>` → verdict | branch | tokens | ~USD | reportDir. Then:

- Read the reportDir envelopes (doc-review, code-review) and summarize their findings — not just the verdict word.
- Tokens are ground truth; USD is an estimate.
- Report the verdict as-is: `green` is done; `degraded`/`failed` gets surfaced with the reasons from the envelopes, never rounded up to "completed".
- The report turn carries no questions. If the envelopes leave decisions open, ask them after the report — one per turn, each a **decision brief** (`~/.claude/shared/decision-brief.md`). Never a one-line "needs your decision" row with a ticket or PR number.

## Cost / time

`se-work` run ≈ work leg (opus) + simplify (two Sonnet-class report legs + one apply + verify, unless the right-sizing gate skips it) + verify-code (claude + opencode). Plan-review is NOT run here — that is the `se-review-and-work` addition. Simplify has strictly more stages than nothing, so it is a real time/cost add over the old flag-less `se-work`, not neutral; a skipped simplify (empty/doc-only/borderline diff) costs almost nothing. Expect ~30-75 min wall clock. Cost lands in the `se list` summary table after the run. For a quick non-durable execution of a small plan, `ce-work` in-session is cheaper.
