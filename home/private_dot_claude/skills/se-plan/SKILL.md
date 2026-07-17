---
name: se-plan
description: "Create structured plans for multi-step work, including software and non-software tasks — the plugin ce-plan workflow, with its document-review step upgraded to the three-envelope review (local personas + external claude + opencode via smithers). Use when asked to plan, break down implementation, plan from requirements, or deepen an existing plan; prefer ce-brainstorm for exploratory framing."
argument-hint: "[optional: feature description, requirements doc path, plan path to deepen, or any task to plan] [output:html]"
---

# Create Technical Plan (wrapper: plugin ce-plan + external doc review)

Thin wrapper over `compound-engineering:ce-plan`. The entire planning workflow is the plugin's — invoke it and follow it faithfully with the **one amendment** below. Do not re-implement, reorder, or skip any of its phases.

## How to run

Invoke the Skill tool with skill `compound-engineering:ce-plan`, passing the original arguments unchanged, and execute its workflow with this amendment:

**Amendment — Phase 5.3.8 Document Review (`references/plan-handoff.md`).** Where the handoff says to run the `ce-doc-review` skill with `mode:headless <plan-path>`: invoke the Skill tool with skill **bare `se-doc-review`** (the user-level wrapper at `~/.claude/skills/se-doc-review`), NOT `compound-engineering:ce-doc-review`, with the same args (`mode:headless <plan-path>`). The wrapper launches the external harness (claude + opencode) in the background FIRST, runs the local plugin review concurrently, waits for both, synthesizes the three envelopes, and returns the combined text — all before control comes back. This ordering is deliberate: everything must settle **before** the post-generation menu renders, because the menu is a stopping point where the user may end the session.

Use the **combined** envelope (local + synthesis) for everything downstream in the plugin workflow: the 5.3.9 final checks, the counts in the summary line above the post-generation menu, and pipeline-mode P0/P1 handling.

## Keep the plugin skill everywhere else

- **Menu option "Decide on the review's open items"** → re-invoke `compound-engineering:ce-doc-review` (the plugin skill, interactive, no `mode:headless`) directly. The external reviews already ran; do NOT go through the wrapper again — that would re-launch the harness and re-bill ~$5-6 for a walkthrough of findings that already exist. Fold the synthesis's unresolved Consensus/Unique/Contradiction items into that walkthrough.
- Any other internal reference the plugin workflow makes to `ce-doc-review` beyond 5.3.8 also means the plugin skill.

## Notes

- **Cost:** the amended review step is ~3x a plain review (~$5-6 external claude leg, opencode on GPT-5.5, ~5-10 min wall clock overlapping the local review). This is intentional — every plan gets the full three-envelope review. For a plan without external review, invoke `compound-engineering:ce-plan` directly.
- **HTML plans** (`output:html`): the plugin skips document review entirely for HTML output; the amendment then never fires and no harness is launched.
- If the current prompt contains `[ce-doc-review-external-consult]`, you are inside an external consult — never invoke this wrapper or launch anything from there (the se-doc-review wrapper's recursion guard governs).

## Amendment 2 — no unresolved P0/P1 review findings on an executable plan

Lesson from the first F3 comparison (2026-07-16): both executor tracks
implemented a plan's unresolved review decisions verbatim, and the pipeline's
own verify-code gate then flagged exactly those decisions as P0s. Executors
do not fix a plan's holes — they replicate them.

After the combined three-envelope review, before rendering the Phase 5.4
post-generation menu: if any **P0 or P1** finding remains in the "Proposed
fixes" or "Decisions" buckets, the plan is NOT done. Do not offer the
execution options (`Start /ce-work`, `Run it as a /goal`) yet. Instead:

1. Say so explicitly ("N P0/P1 review items are unresolved — an executable
   plan must not carry them silently") and route the user into
   `Decide on the review's open items` (interactive `ce-doc-review`).
2. Items the user consciously defers must land in the plan's Open Questions
   section, each marked `blocking` or `deferred`. Any `blocking` item
   downgrades `artifact_readiness` to `requirements-only` (per the
   ce-unified-plan contract) until resolved.
3. Only when zero unrouted P0/P1 items remain (resolved, applied, or recorded
   as deferred-with-rationale) does the full menu render.

P2/FYI findings never gate. Headless/pipeline callers receive the counts in
the envelope and own the decision — this gate is interactive-mode only.
