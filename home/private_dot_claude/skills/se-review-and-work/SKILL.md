---
name: se-review-and-work
description: Plan-review, then execute — `se-work` with the verify-doc stage in front: verify-doc → work → simplify → verify-code → branch. Use when the plan has not been plan-reviewed yet; for an already-reviewed plan, use `se-work`.
argument-hint: "[plan-path] [validate-cmd:'<cmd>'] [setup-cmd:'<cmd>']"
---

# Execute a plan via se-pipeline, WITH plan-review

The same durable pipeline and the same `se` CLI as `se-work`, with the verify-doc plan-review stage turned ON: `verify-doc → work → simplify → verify-code → branch`. Use it when the plan has not been plan-reviewed yet, or the user wants a fresh cross-model plan-review before building.

There is one `se-pipeline.tsx` and one internal `docReview` key; this command sets it, `se-work` omits it. The user picks behavior by command name and never types the flag.

Read `~/.claude/skills/se-work/SKILL.md` and follow its Phases 1–4 (resolve/preflight, launch, monitor, report) exactly, with one change: the launch command adds `--doc-review`.

```bash
cd <repo-root> && se pipeline <plan-path> --doc-review [--validate-cmd '<cmd>'] [--setup-cmd '<cmd>']
```

Everything else — detached by default, never `--attach` in an agent session, `se list` before double-launching, the `waiting-approval` flow, resume-on-kill, the report format — lives in `se-work` and is not restated here.

## Cost / time

`se-work` plus the verify-doc stage: two external plan-review legs (claude + opencode), ~10-20 min, ~$5-6. It is the most expensive path. Expect ~40-90 min wall clock. An already-reviewed plan skips this cost with `se-work`.
