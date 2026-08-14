---
title: The Verification Contract parser reads only tables and fenced blocks, so a bullet-list contract refuses the run at gate 0
type: bug
date: 2026-08-14
status: open
---

# The Verification Contract parser reads only two of the three shapes plans use

## Why this exists

`extractValidateCmd` (`home/private_dot_claude/dot_smithers/workflows/lib/plan.ts:42`) derives the work-gate validation command from a plan's `## Verification Contract` section. It reads commands from exactly two shapes: markdown table rows (`line.trimStart().startsWith("|")`, line 83) and fenced shell blocks (lines 70-81). Every other line in the section is skipped.

A bullet list with inline backticks is the third shape plans are written in, and it yields nothing:

```
$ cd home/private_dot_claude/dot_smithers && bun -e '
const { extractValidateCmd } = await import("./workflows/lib/plan.ts");
console.log(extractValidateCmd("## Verification Contract\n\n- Run `bun run test:scripts` before merging.\n"));'
null
```

A null return means gate 0 refuses the launch before any stage runs. That is the cheapest possible failure — it costs nothing but the operator's round trip — but it is also a launch that looked ready and was not, and the fix is invisible: the plan has to be rewritten into a shape the parser was never documented to require.

Observed on a real launch outside this repo: the plan wrote its contract as a bullet list with inline backticks, gate 0 found zero commands, and the run was refused at 00:00:00. The operator had to add a fenced `bash` block to the plan and relaunch.

The parser's own comment at line 64 names the two shapes as "two shapes in the wild", so this is a coverage gap rather than a deliberate exclusion.

## Scope

`home/private_dot_claude/dot_smithers/workflows/lib/plan.ts` — the line loop in `extractValidateCmd`, plus unit tests in `plan.test.ts`.

Accepting backticked spans from list items is a two-line change: the table-row branch already calls `backtickSpans`, and a list item is recognised by a leading `-`, `*` or `1.` after trimming.

Note what must NOT change with it: a bare paragraph is not a command source. Prose regularly contains backticked identifiers, and `run-1784823010502` already burned the gate once by deriving `(test)` from the sentence "script is `e2e`, not `test`". List items are structured enough to be safe; free paragraphs are not.

## Open decisions

- Whether a plan whose contract exists but yields no commands should refuse (today's behaviour) or fall back to a louder error naming the shapes it accepts. The refusal is correct; the message is what leaves the operator guessing.
