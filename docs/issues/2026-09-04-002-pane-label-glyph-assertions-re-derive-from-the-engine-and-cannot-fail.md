---
title: "Pane-label glyph assertions re-derive from the engine and cannot fail"
short_description: "tests/helpers/herdr_pane_labels.bash defines hpl_icon(), which seds each octal sequence out of the engine it is meant to check, so the 29 HPL_ICON_* assertions in scripts_test.sh compare the engine against itself; the fix that removed this landed in PR #140 and was reverted seven hours later by the herdr-task-sync rename."
type: "bug"
category: "testing-ci"
tags: ["test-integrity","test-oracle","herdr-pane-labels","pua-glyphs","regression"]
date: "2026-09-04"
status: "open"
priority: "medium"
---

## Why this exists

The pane-label suite cannot detect a changed icon codepoint, because its expected values are
read out of the file under test.

`tests/helpers/herdr_pane_labels.bash:19-24` defines `hpl_icon()`, which `sed`s an octal
sequence out of `executable_herdr-pane-labels` and re-expands it:

```bash
hpl_icon() {
  local octal
  octal="$(sed -n "s/^ICON_$1=\"\\\$(printf '\\([^']*\\)')\".*/\\1/p" "$HPL_ENGINE")"
  ...
}
HPL_ICON_BRANCH="$(hpl_icon BRANCH)"     # nf-cod-git_branch U+EC6F
```

The 29 `HPL_ICON_*` assertions in `tests/bashunit/scripts_test.sh` therefore compare the engine
against itself. Change `ICON_BRANCH` in the engine and every one of them still passes.

The helper's own comment states the reasoning backwards:

> The octal UTF-8 table lives once, in the engine; retyping it here would let an engine
> codepoint change pass while the suite still asserted the old bytes.

That is the correct argument for a *generator* — never retype the sequence in code that
produces a glyph — applied to an *oracle*, whose job is the opposite. The distinction is
documented in
`docs/solutions/design-patterns/generate-pua-glyphs-from-octal-printf.md`.

**This was fixed and then reverted.** PR #140 (`92515fe`, 2026-09-02 16:52) removed the
extraction, recording that "temporarily changing `ICON_BRANCH` in the engine now fails 19
previously-passing assertions." PR #73 (`21aaaf0`, 2026-09-02 23:57), the
`herdr-task-sync` -> `herdr-pane-labels` rename, carried the extraction forward as `hpl_icon()`
seven hours later. `git merge-base --is-ancestor 92515fe 21aaaf0` confirms the ordering. The
issue that tracked the discriminator (`2026-09-02-005`) was removed in the closed-issue cleanup,
so the revert has had no tracker since.

What still holds the line is narrower than what PR #140 established:
`tests/bashunit/smoke_test.sh:952-957` pins the five octal sequences as independent literals and
asserts the raw lead byte is absent from the engine. That is a genuine oracle, but it covers five
literals rather than the 29 formatter assertions.

## Scope

Give the icon assertions an oracle independent of the engine. The precedent from PR #140 is to
pin `HPL_ICON_*` as literal octal sequences in the helper, accepting the duplication because
these glyphs are a user-facing pane-label contract with no config or environment override.

Verify the fix the way PR #140 did rather than by inspection: mutate one codepoint in the engine
and confirm the previously-passing assertions go red. Per
`docs/solutions/design-patterns/semantic-regression-tests-over-source-shape.md`, a green suite
after the change proves nothing on its own.

Consider whether the same extraction pattern exists elsewhere in the harness; `hpl_icon()` was
itself introduced as a fix for a hand-duplicated table (`2026-08-20-007`), so the pendulum has
swung both ways here and the reasoning should be written down where the next editor will see it.

## Open decisions

- Pin literals in the helper (PR #140's approach), or extend the `smoke_test.sh` style of
  independent pinning to cover the formatter assertions too?
- Does the widened guard need to prevent a future rename from silently reintroducing the
  derivation, and if so what asserts that?
