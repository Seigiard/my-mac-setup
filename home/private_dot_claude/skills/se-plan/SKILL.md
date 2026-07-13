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
