# `~/.claude/shared/` — reference read by more than one skill

Material that two or more skills need lives here, as a plain file outside the skill system. A skill never points into another skill's `references/` directory: that makes one skill's internals another skill's dependency, and neither owns the result.

## Where a document goes

Count the skills that read it.

| Readers | Home | Examples |
|---|---|---|
| Every session, unconditionally | `~/.claude/CLAUDE.md`, `~/.claude/rules/*.md` (path-scoped), the writing-style output style | global instructions, comment policy, PR rules |
| Two or more skills | **here**, `~/.claude/shared/<name>.md` | `pf-cycle.md`, `se-harness.md`, `decision-brief.md` |
| Exactly one skill | that skill's own `references/` | `herdr-pair/references/peer-protocol.md`, `pf-build/references/demo.md` |

A document with no reader at all does not get created.

When a second skill starts reading something out of a skill's `references/`, that is the moment it moves here — not later.

## Restating a tier-1 rule here is allowed, deliberately

A rule in the always-loaded tier is not reliably applied in a long session: session analysis showed that once the chain grows and the context fills, the writing-style rules stop being followed. A short restatement reached by a pointer at the exact moment of use re-anchors the rule when it matters. `decision-brief.md` exists for that reason and is not a duplication defect.

Two conditions on such a file:

- It names the tier-1 document it re-anchors, so the source of truth stays obvious.
- It earns its place by adding something the tier-1 rule cannot carry — the gate-specific option semantics, in `decision-brief.md`'s case. A file that only copies is still a defect.
