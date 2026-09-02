---
name: se-plan
description: "Plan multi-step work, software or not — the ce-plan workflow with its document-review step upgraded to the three-envelope review. Use to plan, break down implementation, or deepen an existing plan; prefer ce-brainstorm for exploratory framing."
argument-hint: "[optional: feature description, requirements doc path, plan path to deepen, or any task to plan] [output:html]"
---

# Create Technical Plan (wrapper: plugin ce-plan + external doc review)

Thin wrapper over the Compound Engineering `ce-plan` skill. The entire planning workflow is the plugin's — invoke it and follow it faithfully with the **three amendments** below. Do not re-implement, reorder, or skip any of its phases.

## How to run

Invoke the current client's skill tool with the original arguments unchanged: `ce-plan`. Execute its workflow with the amendments.

## Amendment 1 — no scoping-confirmation gate by default

Run the plugin workflow as if `confirm:auto` was passed (`SKIP_SCOPING_CONFIRM=true`): do not stop at the pre-plan scoping-synthesis confirmation ("confirm and I'll write the plan" — plugin Phases 0.7 / 5.1.5). Write the plan directly.

This skips ONLY that confirmation. Everything that asks a real question stays: Phase 0.4 routing, Phase 0.5 product blockers, Phase 2 architecture questions, source-doc disambiguation, the Phase 5.4 post-generation menu, and the P0/P1 gate below. If the user explicitly passes `confirm:ask` (or asks to confirm scope), honor that for the run.

## Amendment 2 — document review through the wrapper

Phase 5.3.8 Document Review (`references/plan-handoff.md`). Where the handoff says to run the `ce-doc-review` skill with `mode:headless <plan-path>`: invoke the current client's skill tool with **bare `se-doc-review`** (the user-level wrapper at `~/.claude/skills/se-doc-review`), not the plugin's `ce-doc-review`, with the same args (`mode:headless <plan-path>`). The wrapper dispatches fresh Claude and OpenCode peers, runs the local plugin review concurrently, closes both peer panes, synthesizes the three envelopes, and returns the combined text before control comes back. This ordering is deliberate: everything must settle **before** the post-generation menu renders, because the menu is a stopping point where the user may end the session.

Use the **combined** envelope (local + synthesis) for everything downstream in the plugin workflow: the 5.3.9 final checks, the counts in the summary line above the post-generation menu, and interactive P0/P1 handling.

## Keep the plugin skill everywhere else

- **Menu option "Decide on the review's open items"** → re-invoke the plugin skill directly (`ce-doc-review`), interactive and without `mode:headless`. The peer reviews already ran; do NOT go through the wrapper again because that would launch another pair. Fold the synthesis's unresolved Consensus/Unique/Contradiction items into that walkthrough.
- Any other internal reference the plugin workflow makes to `ce-doc-review` beyond 5.3.8 also means the plugin skill.

## Notes

- **Cost:** the amended review step runs three multi-persona reviews concurrently: the local pass plus the canonical Claude and OpenCode peers from `~/.claude/shared/herdr-peer-launch.md`. This is intentional. For a plan without peer review, invoke the plugin's `ce-plan` skill directly.
- **HTML plans** (`output:html`): the plugin skips document review entirely for HTML output; the amendment then never fires and no harness is launched.
- If the current prompt contains `[ce-doc-review-external-consult]`, you are inside a peer review. Never invoke this wrapper or launch another pair.

## Amendment 3 — no unresolved P0/P1 findings on an executable plan

Executors do not fix a plan's holes — they replicate them. An executor that
meets unresolved review decisions can implement them verbatim and defer the
same ambiguity to code review.

After the combined three-envelope review, before rendering the Phase 5.4
post-generation menu: if any **P0 or P1** finding remains in the "Proposed
fixes" or "Decisions" buckets, the plan is NOT done. Do not offer execution
options yet. Instead:

1. Say so explicitly ("N P0/P1 review items are unresolved — an executable
   plan must not carry them silently") and route the user into
   `Decide on the review's open items` (interactive `ce-doc-review`).
2. Items the user consciously defers must land in the plan's Open Questions
   section, each marked `blocking` or `deferred`. Any `blocking` item
   downgrades `artifact_readiness` to `requirements-only` (per the
   ce-unified-plan contract) until resolved.
3. Only when zero unrouted P0/P1 items remain (resolved, applied, or recorded
   as deferred-with-rationale) does the full menu render.

P2/FYI findings never gate. Headless callers receive the counts in
the envelope and own the decision — this gate is interactive-mode only.
