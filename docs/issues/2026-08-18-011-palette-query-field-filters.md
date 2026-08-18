---
title: Support field filters in the command palette's query string
type: idea
date: 2026-08-18
status: open
---

## Why this exists

The command palette is a herdr plugin at `home/private_dot_config/herdr/plugins/command-palette/`
(deployed to `~/.config/herdr/plugins/command-palette/`). Its query is a single fuzzy string matched
against one concatenated blob per command: `origin + group + title + description + kind`
(`Command.search_text`, `palette.py:49-51`).

There is no way to narrow by a field. Typing `git` cannot mean "only the Git group"; it competes
with every description that happens to contain those letters. This is the same root cause as the
ranking defect filed against the matcher — one undifferentiated haystack — and a field syntax is the
user-facing half of the fix.

The need grows sharply with the herdr built-in catalog and the dynamic plugin-action source, both
filed separately: those turn a ten-item list into a hundred-item one.

## Scope

A small query language layered over the fuzzy matcher, e.g.:

```
group:git lazy
origin:project deploy
kind:shell
```

`crafts69guy/herdr-switchboard` implements exactly this in about 130 lines including the lexer
(`query.rs:64-133`). Its design decisions worth copying:

- Field filters are typed, with Exact and Contains variants and negation via `-`.
- Quoting is supported, so `cmd:"cargo test"` works.
- **Unknown fields fail closed with a byte-span diagnostic** that the UI underlines, rather than
  being silently ignored. A typo'd filter that quietly matches everything is worse than an error.

Leftover words after the filters are parsed go to the fuzzy matcher as normal.

If the matcher moves to `fzf --filter`, note that fzf's own extended search mode already provides
`'exact`, `^prefix`, `suffix$`, `!negate` and `|` alternation for free — those are complementary to
field filters, not a replacement, since fzf has no notion of our fields.

## Open decisions

- Which fields are addressable: `group`, `origin`, `kind` are obvious; `alias` and `source file` are
  candidates.
- Whether filters are discoverable, and how. Switchboard has a tab strip of group filters that
  auto-narrows to the kinds actually present, which is a better first contact than documentation.
- Whether a field filter narrows the list before scoring or only reweights it.
