---
title: The cached mise activate output freezes the generating shell's PATH into every later shell
type: bug
date: 2026-08-21
status: done
closed: 2026-08-21
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

## Resolution

Decision 1 went to the **strip** variant, kept the cache: the regeneration in
`home/dot_zshenv.tmpl` now pipes `mise activate zsh` through
`sed '1{/^export PATH=/d;}'` before writing the cache, and the mv/rm branch
keys on `$pipestatus[1]` so a failed mise still discards the temp file.

Why stripping is safe was verified on the host, not assumed: `mise activate
zsh | head` confirmed the absolute `export PATH='...'` snapshot is exactly
line 1 (and on this machine it did carry the Claude plugin `bin` dirs the
issue describes), and the activate script *ends with a direct `_mise_hook`
call*, which evals `mise hook-env -s zsh` at source time. So a fresh shell —
including a non-interactive `zsh -f -c`, where precmd never fires — gets
mise-managed tool dirs on `PATH` the moment the cache is sourced: sourcing the
stripped output in a `zsh -f` with a minimal `PATH` resolved `node` to
`~/.local/share/mise/installs/node/lts/bin/node`. No relative shims prepend
was needed. The strip is scoped to line 1 so a legitimate runtime `PATH`
mutation elsewhere in future mise output would survive.

Decision 2 (regenerate on `PATH` change) became moot: with no `PATH` line in
the cache, the cached content is `PATH`-independent, so `PATH`-based
regeneration would add churn and guard nothing. Not implemented.

Decision 3, tests (verified red on the unfixed template by mutation, then
green):

- `tests/templates.bats`: a behavioral test renders `dot_zshenv.tmpl`, points
  it at a fake `mise` (function shim — the rendered file prepends the
  homebrew dirs, so a PATH-based fake would be shadowed by the real mise)
  whose activate output mimics the real shape, generates the cache in a
  throwaway `HOME` with a marker dir on `PATH`, then starts a second zsh with
  a normal `PATH`: the marker must be absent and the runtime mutation line
  must still apply. Plus a render assertion pinning the sed strip. Never
  touches the real `~/.cache` or `$HOME`.
- `tests/smoke.bats`: guards for the `cached_init` consumers in
  `home/dot_zshrc.tmpl` — `starship init zsh`, `zoxide init zsh --cmd cd`,
  `rgrc --aliases` each must emit no `export PATH=` line (skip when the tool
  is absent), so only mise ever had this shape and it stays that way.

Verified: `bats tests/templates.bats` (41/41), `bats tests/smoke.bats` (all
green incl. the three new guards), `make lint`, `make test-templates`.
The fix is commit-ready but not live until `chezmoi apply` deploys it.
