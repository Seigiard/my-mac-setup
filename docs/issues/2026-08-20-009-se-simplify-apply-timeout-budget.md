---
title: se-simplify apply leg dies on APPLY_TIMEOUT_MS in repos with a slow test suite
type: bug
date: 2026-08-20
status: open
---

## Why this exists

Run `85e40697-1cb3-4b25-b4f6-61e17dd2d677` (se-simplify, 2026-08-20 09:24 UTC) ended
`degraded: "apply leg crashed — reverted, no tidy this run"`. Both report legs finished
(4–5 min), synth produced a 14-finding apply set with 0 contradictions, and the apply leg
was killed by the harness at exactly 20 minutes: `APPLY_TIMEOUT_MS = 20 * 60_000` at
`~/.claude/.smithers/workflows/se-simplify.tsx:47`, `retries={0}` on the apply Task
(same file, ~line 397), so there was no second attempt. The verify node then reverted
every apply edit by design.

Where the 20 minutes went (from `smithers chat 85e40697-…`):

- ~12.5 min on THREE baseline bats runs before substantive editing: a full
  `bats tests/scripts.bats` run (~4.4 min), the SAME full run repeated just to count
  ok/not-ok (~4.4 min), and a `--filter herdr-task-sync` run (~3.5 min).
- ~3 min lost to a `` escaping fight (Edit tool vs literal `join("")`,
  resolved via perl + od).
- The kill landed 12 s after the agent launched yet another filtered bats run.

Root cause: the 20-min budget is not sized for a repo where one test-suite run costs
3.5–4.5 min, AND the apply prompt never tells the agent its deadline, so the agent's
(otherwise reasonable) baseline-first caution burns most of the budget. Nothing in
`SIMPLIFY_APPLY_SAFETY_RULES` (`workflows/lib/consult-prompt.ts:86`) asks for test runs —
the verify node runs validate-cmd afterwards anyway; the baselines were the agent's own idea.

## Scope

- `~/.claude/.smithers/workflows/se-simplify.tsx` — `APPLY_TIMEOUT_MS`, the apply Task,
  `applyPrompt()`.
- `~/.claude/.smithers/workflows/lib/consult-prompt.ts` — `SIMPLIFY_APPLY_SAFETY_RULES`.

Candidate fixes (combinable):

1. Tell the apply agent its time budget in `applyPrompt()` and forbid full-suite baseline
   runs (allow `bash -n` / narrowly filtered tests only; verify owns validation).
2. Raise `APPLY_TIMEOUT_MS` or derive it from `validateTimeoutMs` × a factor.
3. Keep `retries={0}` (a retry over half-applied edits is unsafe without a pre-retry
   revert), but then the single attempt's timeout must be generous.

## Open decisions

- Fixed larger timeout vs. scaling from `validateTimeoutMs`.
- Whether to cap the apply-set size per run (14 findings in one 20-min leg was ambitious).
