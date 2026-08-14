## Context

se-pipeline (durable smithers spine in `my-mac-setup`, `home/private_dot_claude/dot_smithers/workflows/`) has two review stages with asymmetric gate power:

- **verify-code** returns structured JSON (`verdict`, `findings[].severity`) → `codeReviewGate` blocks on `P0 > 0` (KTD3). Proven in run-1784221992328: paused on 3×P0 before landing.
- **verify-doc** returns two free-form markdown envelopes (claude + opencode legs). `docReviewGate` (`lib/gates.ts:78`) can only check that the legs *ran* — it never reads findings. A P0-grade flaw in the plan review does not stop the pipeline.

Mitigation already in place (2026-07-24, uncommitted at filing time): `readDocReviewAdvisory` threads both envelopes into the work-agent prompt as advisory context. The agent sees the findings; the deterministic gate still cannot act on them.

## Task

Make the verify-doc gate able to block on high-severity plan findings.

Required pieces:

1. **Structured output from both review legs** — extend the consult prompt contract (`se-doc-review.tsx`, `lib/consult-prompt.ts`) so each leg returns a machine-readable severity summary alongside (not instead of) the markdown envelope. E.g. a trailing JSON line or a separate field: `{"maxSeverity": "P2", "p0Count": 0, "p1Count": 3}`.
2. **Schema + validation** — extend `docReviewSchema` / `outputSchema`; keep the current "≥500 chars, ends with 'Review complete'" envelope check as-is (strict JSON-only contracts on review legs failed capture before — that's why the envelope is free-form).
3. **Gate logic** — `docReviewGate` blocks on P0 (mirror KTD3), advisory on P1; two-leg disagreement policy needed (max of the two legs — fail-closed).
4. **Tests** — `gates.test.ts` cases: P0 blocks, P1 advisory, severity missing → today's behavior (leg-availability only), legs disagree.

## Risks / prior art

- LLM legs violating strict output contracts was the original reason the envelope is free-form text. The severity summary must be tolerant: unparseable summary → fall back to advisory-only gating, never fail the leg.
- Waive path: mirror verify-code (`waiveOnApprove` — operator can approve past a P0 with the reason recorded in run notes).

## Verification

- `bun test` in `home/private_dot_claude/dot_smithers` green (gates.test.ts extended).
- Smoke run: `se pipeline` fixture with an injected P0 summary pauses at `gate-verify-doc`.
