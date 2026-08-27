---
name: plan-explainer
description: Explain a plan or spec document as a visual HTML page for a reader with no context on it — what it does, how it gets done, what it refuses to build, and what each stage hands back. Use when the user asks to explain, walk through, or visualize a plan, or asks in Russian ("объясни план", "какие там этапы").
---

# Plan Explainer

Turn one plan document into one HTML page that a reader with no domain knowledge can use to answer four questions:

1. **What** does this change, and what problem does it solve?
2. **How** does it get done — in what order, and why that order?
3. **What does it refuse to build?**
4. **What lands in my hands after each stage?**

Big pictures, few words. Prose is the fallback, not the medium.

## Ground rules

**Grounded.** Every picture, label and number on the page traces to a line in the plan. A phrase earns its place by appearing in the plan first. *Grounded* is the word the rest of this skill uses for that property — the self-review step checks it, and `references/sections.md` names the framing devices that fail it.

**The plan is the only source.** Work from the plan text alone. Repeat a filename the plan already names; leave the file itself closed.

**Verified means seen.** A section counts as verified once its screenshot has been read; step 5 carries the mechanic.

**Numbers come from the plan.** An invented range reads as fact. Report what stayed unverified.

**Stay read-only on the plan.** This skill only explains — plan edits, new requirements and test obligations stay the user's call. To change the plan, say so and ask.

## Drawing rules

**Concrete before abstract.** The first picture shows the real thing in the reader's own terms — the screen, the row, the message they would actually see. Architecture, cycles and stage maps come after that anchor.

**Mark what already exists.** Any picture of machinery separates what is already there from what this plan adds. Without that split a reader cannot judge size, and every plan looks like a rewrite.

**Keep the plan's altitude.** When the plan describes something broad, draw the general shape and label the motivating example as one instance of it.

**The page stands alone.** A reader arriving from a bare link has never seen the chat or any earlier draft. Write every claim as a standing fact about the plan: *the row shows the branch and its counts*.

**Keep sections orthogonal.** Each section answers something no other section can.

**Placeholders where the plan gives no value.** When the plan names a UI field but supplies no literal for it, render a neutral label built from the plan's own noun — `folder-name`, `worktree identity`. A realistic-looking branch, repository, user or timestamp invented to fill the slot reads as fact. Values inside mocks and paper cards look decorative, which is why the self-review step checks them too.

**Name the stage by what it does.** A reader with no context cannot resolve `U3` or `KTD2` — put the plan's identifier in parentheses at most.

## When not to build a page

A plan whose whole content fits in three sentences deserves three sentences. Say so and answer in chat. Build the page when the plan has stages, refusals or acceptance criteria a reader must hold at once.

## Workflow

### 1. Inventory the plan

Read the whole document, start to end. Then list what it carries. Most plans hold some of:

| Family | The reader's question it answers |
|---|---|
| Ground rules / key decisions | How is the work run? |
| Requirements | What must be true at the end? |
| Acceptance examples, matrices | How will we check? |
| Technical decisions / constraints | What must not be built? |
| Stages, units, steps | In what order? |
| Verification gates, definition of done | When is it over? |

Count each family. Counts are content: "6 requirements, 5 refusals, 3 stages" orients a reader faster than any paragraph.

When the plan carries no labels, derive the same families from its prose. Every plan has an end state, a forbidden set, an order and a finish line, whether or not they are numbered.

Note which stages produce a **document** (an observation, a filled table, a decision written down) and which produce **running behavior**. That split drives the deliverables section.

**Done when** every family in the table carries a count, including the zeroes.

### 2. Choose the sections

Default spine, in this order: the whole picture · vocabulary · now vs. wanted · the behavior · the route · the refusals · the scoreboard · what each stage hands back · what is still open.

`references/sections.md` gives each one its visual form and the plan content that feeds it. Include a section when a specific plan passage supports it; when one has no such passage, drop it and name it in the final report.

**Done when** every section on the spine is either claimed by a plan passage or recorded as dropped.

### 3. Build the page

Pull each chosen section's markup sketch from `references/sections.md` — that sketch is the shape to fill.

`references/page-craft.md` carries the page skeleton, theme tokens, mermaid usage, delivery mechanics for both hosts, the verification recipe, and the traps that bite in a growing single-file page.

Write the file to the scratchpad when publishing through the Artifact tool. On a host without that tool, write straight to the durable path `page-craft.md` names, because the file is itself the deliverable.

Write the page in the language the plan is written in unless the user asks otherwise.

**Done when** the file holds every section chosen in step 2.

### 4. Self-review against the plan

Walk the finished page with the plan open beside it and check groundedness: every claim, number and label traces to a line in the plan. Delete whatever does not. Check the values inside mocks and paper cards, which look decorative and hide invented literals. Check that every domain term is either a vocabulary card or defined where it first appears.

**Done when** every remaining line on the page is grounded in the plan.

### 5. Deliver and verify

Publish through the Artifact tool where it exists and hand back the URL; elsewhere hand back the absolute path and a copyable `open` command. Then run `scripts/capture-sections.sh` and satisfy every required row of the check table in `references/page-craft.md`.

**Done when** every row marked required in that file's check table is satisfied.

### 6. Report

State the URL or the file path, name each section and the plan content behind it, name every section dropped in step 2, and split verified from not verified per the Reporting section of `references/page-craft.md`.

**Done when** the report carries the delivery location, every shipped section with its plan content, every dropped section, and the verified/not-verified split.

## Branches

`references/edge-cases.md` covers three cases that arrive on their own: a second pass over a page that already exists, a request for several candidate versions of a section, and being stuck on what shape a section should take.

## Additional resources

- **`references/sections.md`** — the section catalogue, used in steps 2 and 3.
- **`references/page-craft.md`** — build, delivery, verification and reporting mechanics, used in steps 3, 5 and 6.
- **`references/edge-cases.md`** — iteration, variants, and getting unstuck.
- **`scripts/capture-sections.sh`** — one-command capture of every section, used in step 5.
