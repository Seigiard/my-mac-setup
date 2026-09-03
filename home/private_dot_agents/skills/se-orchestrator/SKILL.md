---
name: se-orchestrator
description: Execute a plan through its checklist — take the first unchecked item, do it, verify, commit the work and the checkbox together. Use to run, continue, or resume a plan, spec, or TODO document, whether structured or hand-written, and when asked where to continue from. Writing the plan is ce-plan; an open-ended bug is ce-debug.
---

# Execute a plan through its checklist

The plan file is the state. The first unchecked box is where you continue. Nothing else is stored.

Four rules carry the whole workflow:

1. **One item is one commit**, and the repository works after it.
2. **The checkbox rides in that same commit.**
3. **You continue from the first unchecked item.**
4. **You run the verification and you own the commit.** The worker does neither.

Rule 2 is why there is no journal: a commit that exists proves its box is checked, and a checked box proves its commit exists. `git log` is the run history, and `git status` answers "was I interrupted mid-item".

## Step 1 — Put a checklist in place

Read the plan. When it already carries a checklist, adopt it unchanged.

Otherwise derive one and show it to the user before the first code edit. This is the only gate in the run; everything after it runs to the end or to a blocker.

- Each item names one outcome, sized so the repository works once it lands.
- Item labels stay whatever the document already uses — `U3`, `Step 2`, `Раздел «Адаптеры»`, `First part`. You read them the way a human would; no parser touches them.
- When you cannot say how an item would be checked as done, ask about **that item**. Keep the question local; a plan needing one clarification is a plan you accept.

The checklist lives inside the plan when the plan is writable, otherwise in `TODO.md` beside it. Exactly one file holds it.

```
## Progress

- [x] U1 · state library
- [ ] U2 · engine skeleton
```

**Done when:** every item has a stated done condition and the user has accepted the list.

## Step 2 — Work the first unchecked item

Pick the executor by what the item needs, and default to the middle rung:

| Executor | Fits |
|---|---|
| Yourself, inline | One or two files, where a worker costs more than the work |
| A fresh subagent | The default: one worker per item, clean context |
| A visible pane | Long items, or anything running an observable process — load the `herdr` skill when `HERDR_ENV=1` |

Hand the worker five things and nothing else:

- The item text and the plan path. Sending "read the whole plan" spends its context on material it will not use.
- The repository's own verification commands, read from its instructions (`CLAUDE.md` / `AGENTS.md`) at dispatch time rather than recalled.
- The files this item owns.
- **Leave the commit to you** — the git index is yours alone.
- **Show the failing output it saw before fixing.** That observation exists only while the worker works; the diff cannot reconstruct it afterwards.

Then integrate, in this order:

1. Read `git status` and the diff. The tree is the truth; the worker's summary is a hint about where to look.
2. Run the verification yourself.
3. Tick the box in the checklist file, then commit through `ce-commit` so the work and the `[x]` land together.

**Done when:** verification passes and one commit carries both the change and its checked box.

Then return to Step 2 for the next unchecked item.

## Step 3 — Decide where to continue

Run this on every entry, including a fresh session, a session after `/clear`, and a resumed one:

| State | Move |
|---|---|
| Working tree dirty | Someone was interrupted mid-item. Read the diff. When it is this item's work, finish and commit it. When it is someone else's, **preserve it and ask** — discarding it is the one way this workflow loses anything |
| Clean, unchecked items remain | Take the first one |
| First unchecked item carries a `blocked` line | Skip it and take the next unchecked item |
| Every remaining item is blocked | Stop and put the blockers to the user |
| Every item checked | Go to Step 4 |

A blocked item stays unchecked and gains one line under it:

```
- [ ] U6 · client adapters
      blocked 2026-09-03: pi has no async tool_call, needs a decision
```

## Step 4 — Finish

1. Run `se-code-review` once over the completed work.
2. Apply findings that are clear improvements and reversible edits. Leave contradictions between reviewers, taste calls, and design decisions to the user.
3. A finding asking for a new test passes the oracle gate first: name the consumer, the observable failure, and an oracle independent of the reviewed diff. When the line will not complete, keep the finding advisory and say why.
4. Re-run the verification and commit the fixes.
5. Report what landed, what stayed blocked, and what the review left open.

Push and PR are a separate explicit request routed through `ce-commit-push-pr`.

## Stop and put it to the user

- The derived checklist, before the first code edit.
- The same failure three times. Name the assumption that may be wrong instead of trying a fourth variation.
- Every remaining item blocked.
- Reviewers contradicting each other on whether an issue exists.
- A working-tree change that no item of yours accounts for.

## Working in parallel

Serial is the default and usually the honest answer: items in one plan tend to share a test file or a module, and the sharing is what forces the order, not the dependency list. Take two items at once only after reading the files they name and finding no shared write surface — then still commit them one at a time, in dependency order.
