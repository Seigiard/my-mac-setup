---
name: plan-explainer
description: Explain a plan or spec document as a published HTML artifact for a reader with zero context — what it does, how it gets done, what it refuses to build, and what lands after each stage. Use when the user asks to explain a plan, asks for a plan "like I know nothing about this topic", wants big pictures and few words about a plan, asks what a plan will actually do or how hard it is, or asks in Russian ("объясни план", "что делает этот план", "как он будет это делать", "какие там этапы").
---

# Plan Explainer

Turn one plan document into one published HTML artifact that a reader with no domain knowledge can use to answer four questions:

1. **What** does this change, and what problem does it solve?
2. **How** does it get done — in what order, and why that order?
3. **What does it refuse to build?**
4. **What lands in my hands after each stage?**

Big pictures, few words. Prose is the fallback, not the medium.

## Non-negotiables

**Every picture is built from the plan's own content.** Never invent a lens, a difficulty scale, an hours estimate, or a generic list of "common traps". If a phrase is not in the plan, it does not go on the page. Decorative frames — dot-scales, generic checklists, abstract "perspectives" — teach nothing and get rejected.

**The plan is the only source.** Do not open the code to explain the plan. A plan says what will become true and what is forbidden; that is the material. Naming a file the plan already names is fine. Going to read that file is not.

**Look at the page before calling it done.** Render it, screenshot it, read the screenshots. Publishing unseen is not finished work. See `references/page-craft.md`.

**Keep measured and assumed apart.** Numbers that appear in the plan can appear on the page. Numbers that do not, cannot — an invented range reads as fact. Report what stayed unverified.

**Add nothing to the plan.** This skill explains; it does not edit the plan, add requirements, or invent test obligations. To change the plan, say so and ask.

## Drawing rules

**Concrete before abstract.** The first picture shows the real thing in the reader's own terms — the screen, the row, the message they would actually see. Architecture, cycles, and stage maps come after that anchor, never before it.

**Mark what already exists.** Any picture of machinery separates what is already there from what this plan adds. Without that split a reader cannot judge size, and every plan looks like a rewrite.

**Keep the plan's altitude.** A motivating example is not the whole scope. When the plan describes something broad, draw the general shape and label the example as an example; do not let one screenshot silently become the definition.

**The page stands alone.** A reader arriving from a bare link has never seen the chat, the earlier draft, or any label invented along the way. Ban revision language: no "unlike the earlier version", "as shown above in the variant", "this pass adds". State the thing positively.

**No two sections carry the same load.** Each section answers something the others cannot. When a new section overlaps an old one, one of them goes.

## When not to build a page

A plan whose whole content fits in three sentences needs three sentences, not a page. Say so and answer in chat. Build the artifact when the plan has stages, refusals, or acceptance criteria a reader must hold at once.

## Workflow

### 1. Inventory the plan

Read the whole document first. Then list what it actually carries. Most plans hold some of:

| Family | The reader's question it answers |
|---|---|
| Ground rules / key decisions | How is the work run? |
| Requirements | What must be true at the end? |
| Acceptance examples, matrices | How will we check? |
| Technical decisions / constraints | What must not be built? |
| Stages, units, steps | In what order? |
| Verification gates, definition of done | When is it over? |

Count each family. Counts are content: "6 requirements, 5 refusals, 3 stages" orients a reader faster than any paragraph.

When the plan carries no labels, derive the same families from its prose. Every plan has an end state, a forbidden set, an order, and a finish line, whether or not they are numbered.

Note which stages produce a **document** (an observation, a filled table, a decision written down) and which produce **running behavior**. That split drives the deliverables section.

### 2. Choose the sections

Default spine, in this order:

1. The whole picture — the situation, drawn.
2. Vocabulary — every domain term the page will use, one picture each.
3. Now vs. wanted — the gap, side by side.
4. The behavior — the loop or state machine, when the plan describes one.
5. The route — stages in fixed order, with the decision that gates them.
6. The refusals — what the plan deliberately does not build.
7. The board — the acceptance criteria as a scoreboard.
8. What each stage hands back — the artifacts.
9. What is still open — decisions the plan deliberately left unmade.

Drop a section when the plan has nothing for it, and say which and why in the final report. Never pad.

`references/sections.md` holds the visual form for each one, with what plan content feeds it.

### 3. Build the page

Write a single self-contained HTML file to the scratchpad. `references/page-craft.md` carries the page skeleton, theme tokens, mermaid usage, and the traps that bite in a growing single-file page.

Write the page in the language the plan is written in unless the user asks otherwise.

### 4. Self-review against the plan

Walk the finished page once with the plan open beside it. Every claim, number, and label must trace to a line in the plan. Delete anything that cannot. Check that every domain term used on the page appeared in the vocabulary section first.

### 5. Deliver and verify

Two hosts, one file. Where the Artifact tool exists, publish with it and hand back the URL. Where it does not — OpenCode and every other host — the deliverable is the HTML file itself: write it to a durable path, never a temp directory, and hand back that absolute path. Keep the page self-contained either way so it survives being moved or mailed.

Then render the local file, screenshot each section, and read the screenshots. Fix what looks wrong before reporting. Both recipes are in `references/page-craft.md`.

### 6. Report

State the URL or the file path, name each section and the plan content behind it, and separate what was checked visually from what was not.

## Growing an existing page

When the user asks for another pass on a page that already exists:

- Republish the **same file path** — with the Artifact tool the URL is preserved, and without it the reader's bookmark still resolves. A new path means a second copy and a stale link.
- Before adding a section, check whether an existing one now duplicates it. A page that says the same thing twice is worse than a page that says it once. Flag a duplicate and offer to cut it; do not silently restructure.
- Keep section numbering coherent, or drop numbering entirely.

## When asked for variants

Offering several candidate versions of a section is legitimate only when each candidate carries real content from the plan. Four differently-framed empty boxes are not a choice, they are four failures. Build each variant from a different family of plan content — the route from the stages, the mass from the refusals, the board from the acceptance criteria — so that picking one is picking a lens on real material.

## Getting unstuck on form

When the shape of a section is unclear, ask a peer model for framing ideas before drawing: `ask-in-herdr` for a live peer, or a one-shot `opencode run "<brief>"`. Give the peer the plan's inventory and the reader profile, never the raw plan dump, and ask for concrete visual forms rather than opinions. Independent peers converging on the same form is a strong signal.

## Additional resources

- **`references/sections.md`** — the section catalogue: visual form, the plan content that feeds it, and a markup sketch for each.
- **`references/page-craft.md`** — page skeleton, theme tokens, mermaid, publishing mechanics, and the self-verification recipe with its known limits.
