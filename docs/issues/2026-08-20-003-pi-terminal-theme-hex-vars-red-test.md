---
title: "Test \"Pi terminal theme uses only terminal palette colors\" is red on main — terminal.json .vars holds hex strings"
type: bug
date: 2026-08-20
status: done
closed: 2026-08-20
---

## Why this exists

`bats tests/scripts.bats` fails on a clean `main` checkout:

```
not ok 182 Pi terminal theme uses only terminal palette colors
# (in test file tests/scripts.bats, line 4668)
```

The assertion at `tests/scripts.bats:4657-4667` requires every value in
`home/dot_pi/agent/themes/terminal.json` `.vars` to be a number in `0..15`
(an ANSI palette index). Four entries are hex color strings instead:

```
$ jq '[.vars[]] | map(select((type=="number" and .>=0 and .<=15)|not))' home/dot_pi/agent/themes/terminal.json
[ "#6F6E69", "#878580", "#B7B5AC", "#F2F0E5" ]
```

Origin: commit `538db0e fix(pi): darken terminal theme muted text` (2026-08-20)
introduced the hex values. The test itself came from `ee5357b feat(agents):
inherit terminal color palettes (#20)`. The commit that broke the test did not
update the test, so `main` has shipped red since `538db0e`.

The failure predates the herdr label-system range (`46f226c..HEAD`) — verified
with `git merge-base --is-ancestor 538db0e 46f226c`. It is unrelated to herdr
labels, but it makes the label-system verification gate
(`bash -n home/dot_local/bin/executable_herdr-task-sync && bats tests/scripts.bats
&& bats tests/smoke.bats`) unusable as a pass/fail signal: any run reverts on a
failure it did not cause.

## Scope

Pick one and make code and test agree:

- The muted-text darkening from `538db0e` is intended → widen the test to allow
  hex strings for the muted-text vars, and say in the test why those four are
  exempt.
- The palette-only contract is intended → replace the four hex values with ANSI
  palette indices and re-check the rendering that `538db0e` was fixing.

Then re-run `bats tests/scripts.bats --filter 'Pi terminal theme'`.

## Preliminary decision (2026-08-20)

The palette-only contract wins: `mutedText`, `dimText`, `subtleLine` and `softBg`
go back to ANSI palette indices, and the test at `tests/scripts.bats:4657` stays
as written. The darkening from `538db0e` is given up rather than encoded as hex.

Second half of the decision, not yet designed: the repo needs a **theme tester** —
a way to see a `home/dot_pi/agent/themes/*.json` scheme rendered before committing
it, so picking an index is a look-at-it choice instead of a guess. Without it the
next person who wants darker muted text has the same reason to reach for hex.

## Open decisions

- Which ANSI indices replace the four hex values, judged against the rendering
  `538db0e` was trying to fix.
- What shape the theme tester takes: a script that prints every `colors` key in
  its resolved color, a bats assertion over the schema, or both.
- Whether any other `home/dot_pi/agent/themes/*.json` file carries the same
  mismatch (only `terminal.json` is asserted today).

## Resolution (2026-08-20)

Fixed in commit `8cb70d8` — `fix(pi): return terminal theme vars to ANSI palette
indices`. The palette-only contract won, as per the preliminary decision.

- **Indices chosen:** `mutedText`, `dimText`, `subtleLine` → `8`; `softBg` → `15`.
  Slot 7 (Flexoki's muted gray, which the hex values were copied from) is
  unusable: on the active Alabaster kitty palette, slot 7 is `#f7f7f7` — the
  background color, so slot-7 text would be invisible. Slot 8 is the only
  readable gray on both managed palettes (Alabaster `#777777`, Flexoki
  `#b7b5ac`). `softBg` → `15` blends with the background on Alabaster (an
  accepted degradation of that palette) but keeps box text readable, unlike the
  pre-`538db0e` `gray`(8) background. The darkening from `538db0e` is given up.
- **Tests:** `bats tests/scripts.bats --filter 'theme'` — 3/3 green, including
  the previously red "Pi terminal theme uses only terminal palette colors";
  `bats tests/smoke.bats --filter 'coding agents use terminal color palettes'`
  green.
- **Theme tester:** designed as a browser playground in
  `docs/brainstorms/2026-08-20-terminal-theme-playground.md` — a separate-repo
  static page previewing Claude Code / opencode / pi mock layouts against a
  configurable terminal ANSI palette, with per-token slot editing and
  copy-to-clipboard export.
- **Other pi theme files:** `home/dot_pi/agent/themes/` contains only
  `terminal.json`; no other file can carry the mismatch.
