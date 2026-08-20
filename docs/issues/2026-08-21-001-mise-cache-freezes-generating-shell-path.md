---
title: The cached mise activate output freezes the generating shell's PATH into every later shell
type: bug
date: 2026-08-21
status: open
---

## Why this exists

`home/dot_zshenv.tmpl:35-58` caches the output of `mise activate zsh` in
`~/.cache/zsh/mise-activate.zsh` and sources that file on every shell start.
Line 1 of that output is an absolute `export PATH='...'` assignment, captured
from whichever shell happened to regenerate the cache.

Consequence: whatever `PATH` that one shell had gets pinned for every shell
afterwards, until the cache is regenerated. Two observed shapes of the problem:

- A shell started from a tool with an augmented `PATH` bakes those entries in.
  A real capture on this machine held Claude Code plugin `bin` directories
  (`~/.claude/plugins/cache/.../bin`) in the cached line, so ordinary terminals
  would have inherited them.
- The reverse: a shell with a trimmed `PATH` regenerates the cache and every
  later shell silently loses entries it used to have.

The cache is regenerated only when the mise binary is newer than the cache file
(`home/dot_zshenv.tmpl:38`), so a bad capture persists across reboots and can
survive for weeks.

This is a distinct defect from the concurrent-write splice fixed on 2026-08-21
(commit adds `mktemp` + `mv` to `home/dot_zshenv.tmpl` and to `cached_init` in
`home/dot_zshrc.tmpl`). The atomic write makes the cache a faithful copy of one
shell's output; it does not make that output shell-independent. The differing
`PATH` lengths between two shells were what made the splice visible at all.

## Scope

In scope:

- `home/dot_zshenv.tmpl:35-58` — the mise cache block.
- The equivalent question for `cached_init` consumers in
  `home/dot_zshrc.tmpl:85-101`: `starship init zsh`, `zoxide init zsh`, and
  `rgrc --aliases` were checked on 2026-08-21 and none of them embeds a `PATH`
  assignment, so today only mise is affected. A test should keep it that way.

Out of scope: the caching strategy itself. The caches exist to avoid a subshell
fork per shell start, and that trade-off is not being reopened here.

## Open decisions

1. **Strip the `PATH` line from the cached output, or stop caching mise.**
   Stripping means the cache carries only the hooks and the handler, and `PATH`
   comes from `_mise_hook` at runtime — needs a check that mise's activate
   output stays correct without its first line. Dropping the cache costs the
   ~10ms fork the cache was added to avoid.
2. **Whether to regenerate on `PATH` change** rather than only on a newer mise
   binary. Cheap to detect (compare a hash of `PATH` against one recorded in the
   cache), but it reintroduces a regeneration on every `PATH` variation.
3. **Which test proves it.** A candidate: render `dot_zshenv.tmpl`, generate the
   cache under an unusual `PATH`, start a second shell with a normal `PATH`, and
   assert the second shell's `PATH` does not contain the marker entry.
