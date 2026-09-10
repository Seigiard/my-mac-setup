# `~/.claude/shared/` — reference reached from more than one place

Material reached from more than one place — two or more skills, or a pointer out of an always-loaded document — lives here, as a plain file outside the skill system. A skill never points into another skill's `references/` directory: that makes one skill's internals another skill's dependency, and neither owns the result.

## Where a document goes

Count the readers, and note when they read it.

| Readers | Home | Examples |
|---|---|---|
| Every session, unconditionally | `~/.claude/CLAUDE.md`, `~/.claude/rules/*.md` (path-scoped), the writing-style output style | global instructions, comment policy, PR rules |
| Two or more skills, or one pointer from an always-loaded document | **here**, `~/.claude/shared/<name>.md` | `pf-cycle.md`, `herdr-peer-launch.md`, `child-agent-contract.md`, `long-running-work.md` |
| Exactly one skill | that skill's own `references/` | `pf-build/references/implementer-prompt.md`, `pf-build/references/demo.md` |

A document with no reader at all does not get created.

When a second skill starts reading something out of a skill's `references/`, that is the moment it moves here — not later.

## A pointer out of an always-loaded document

`~/.claude/CLAUDE.md` is loaded in every session, but most of what it could say is not live in most of them. The trigger stays there as one `<important if>` block and the body waits here, reached only when the situation arises. `long-running-work.md` is reached that way.

Two conditions on such a file:

- It names the document that points at it, so the source of truth stays obvious.
- It earns its place by carrying what a trigger cannot — the ordered contract, the failure patterns. A file that only restates its trigger is still a defect.

No separate directory is created for a file with one reader reached this way.
