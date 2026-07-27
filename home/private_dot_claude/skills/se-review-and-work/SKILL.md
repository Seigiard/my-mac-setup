---
name: se-review-and-work
description: Execute an implementation-ready plan via the durable se-pipeline (smithers) WITH plan-review first — verify-doc → work → simplify → verify-code → branch/PR, plus secret-scan gates, approval pauses, and a cost summary. Use when a plan should be plan-reviewed before it is built. It is `se-work` with plan-review turned on; for an already-reviewed plan, use `se-work`.
argument-hint: "[plan-path] [until:pr] [validate-cmd:'<cmd>']"
---

# Execute a plan via se-pipeline, WITH plan-review (wrapper over the `se` CLI)

This is the **full** variant of `se-work`: the same durable pipeline and the same `se` CLI, with the verify-doc plan-review stage turned ON. Stage sequence: `verify-doc → work → simplify → verify-code → branch/PR`. Use it when the plan has NOT yet been plan-reviewed (or you want a fresh cross-model plan-review before building). For an already-prepared, human-reviewed plan, use **`se-work`** instead — it is this command with plan-review turned off.

There is one `se-pipeline.tsx` and one internal `docReview` key; this command sets it (`se pipeline … --doc-review`), `se-work` omits it. The user picks behavior by command name and never types the flag. The **simplify** stage runs in BOTH commands — it is always present and autonomously run-or-skipped, not a flag; so `se-review-and-work` keeps verify-doc AND adds simplify, a pure cost add over the old full `se-work`.

All orchestration is **code**, not prose: the `se` CLI (`~/.claude/.smithers/bin/se`, on PATH as `se`) wrapping the smithers workflow `~/.claude/.smithers/workflows/se-pipeline.tsx`. Do not re-implement stages, gates, or resume logic — launch and observe. Troubleshooting source of truth: `docs/se-pipeline.md` in the my-mac-setup repo.

Argument contract (identical to `se-work`): an optional plan path; `until:pr` maps to `--until=pr`; `validate-cmd:'<cmd>'` maps to `--validate-cmd` (override only — omitted, the workflow derives it from the plan's Verification Contract).

Follow the `se-work` skill for Phases 1–4 (resolve/preflight, launch, monitor, report) EXACTLY, with one difference:

## Launch — pass `--doc-review`

```bash
cd <repo-root> && se pipeline <plan-path> --doc-review [--until=pr] [--validate-cmd '<cmd>']
```

That single `--doc-review` flag is the only thing that differs from `se-work`. Everything else — detached-by-default, never `--attach` in an agent session, `se list` before double-launching, the `waiting-approval` gate flow, resume-on-kill, the report format — is identical to `se-work`; do not duplicate that logic here, follow `se-work`.

## Cost / time

`se-review-and-work` run ≈ verify-doc (two external plan-review legs: claude + opencode, ~10-20 min, ~$5-6) + work leg (opus) + simplify (two Sonnet-class report legs + one apply + verify, unless its gate skips it) + verify-code (claude + opencode). It is the most expensive path — the full plan-review AND the simplify add-on. Expect ~40-90 min wall clock. If the plan is already reviewed, `se-work` skips the plan-review cost.
