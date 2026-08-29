# `~/.claude/shared/` — reference reached from more than one place

Material reached from more than one place — two or more skills, or a pointer out of an always-loaded document — lives here, as a plain file outside the skill system. A skill never points into another skill's `references/` directory: that makes one skill's internals another skill's dependency, and neither owns the result.

## Where a document goes

Count the readers, and note when they read it.

| Readers | Home | Examples |
|---|---|---|
| Every session, unconditionally | `~/.claude/CLAUDE.md`, `~/.claude/rules/*.md` (path-scoped), the writing-style output style | global instructions, comment policy, PR rules |
| Two or more skills, or one pointer from an always-loaded document | **here**, `~/.claude/shared/<name>.md` | `pf-cycle.md`, `herdr-peer-launch.md`, `decision-brief.md`, `child-agent-contract.md`, `long-running-work.md` |
| Exactly one skill | that skill's own `references/` | `pf-build/references/implementer-prompt.md`, `pf-build/references/demo.md` |

A document with no reader at all does not get created.

When a second skill starts reading something out of a skill's `references/`, that is the moment it moves here — not later.

## Restating a tier-1 rule here is allowed, deliberately

A rule in the always-loaded tier is not reliably applied in a long session: session analysis showed that once the chain grows and the context fills, the writing-style rules stop being followed. A short restatement reached by a pointer at the exact moment of use re-anchors the rule when it matters. `decision-brief.md` exists for that reason and is not a duplication defect.

Two conditions on such a file:

- It names the tier-1 document it re-anchors, so the source of truth stays obvious.
- It earns its place by adding something the tier-1 rule cannot carry — the gate-specific option semantics, in `decision-brief.md`'s case. A file that only copies is still a defect.

A pointer from `~/.claude/CLAUDE.md` is that same case with one reader instead of two: the rule is always loaded but not always live, so the body waits here and the tier-1 file carries only the trigger. `long-running-work.md` is reached that way. The two conditions above still apply, and no separate directory is created for it.
