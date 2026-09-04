---
title: Generate PUA glyphs from octal printf — never paste them
date: 2026-08-21
category: design-patterns
module: herdr
problem_type: convention
component: tooling
severity: medium
related_components:
  - development_workflow
applies_when:
  - "Embedding Nerd Font or other private-use-area (PUA) glyphs in a shell script or managed dotfile"
  - "Writing a script that must run under macOS system bash 3.2"
  - "A file containing icon glyphs will pass through editors, coding agents, or diff/review tooling"
  - "Choosing between pasting a literal Unicode character and generating it at runtime with printf"
  - "Label or status-line width math must count codepoints for multi-byte icons"
symptoms:
  - 'An icon renders as tofu or a replacement character after an unrelated edit to the file'
  - '`printf` with a \uXXXX escape under bash 3.2 prints the literal text instead of the glyph'
  - 'A pasted PUA glyph silently changed or vanished after the file passed through an agent or editor'
tags:
  - bash-3-2
  - nerd-fonts
  - codicons
  - printf-octal
  - pua-glyphs
  - unicode
  - shell-portability
  - herdr
---

# Generate PUA glyphs from octal printf — never paste them

## Context

Nerd Font icons (codicons, material icons) live in Unicode's Private Use Area — e.g. `nf-cod-git_branch` is U+EC6F. Any shell script that renders a font-dependent TUI (herdr labels, tmux status lines, shell prompts, sketchybar configs) needs to emit those codepoints. Two constraints collide:

1. **Raw PUA glyphs in source are fragile.** Without the patched font, editors, terminals, diff views, and agents render them as tofu or replacement characters — and text-normalizing tooling can silently corrupt them. The corruption is invisible in review because the before and after look identically broken.
2. **macOS ships bash 3.2** (the GPLv2 freeze), and herdr scripts and hooks run under it. bash 3.2's `printf` understands `\NNN` octal byte escapes but NOT `\uXXXX` unicode escapes (those arrived in bash 4.2).

The failure was hit live during the icon-set selection for the herdr label system (session history, 2026-08-20): the first glyph-candidate card written into a herdr pane lost most of its pasted icon characters on file write — the pane showed lines with no glyphs at all — and worked only after the file was regenerated programmatically from codepoints. That incident is the direct precedent for the shipped rule.

## Guidance

Never paste a PUA glyph literally into a script. Generate it at runtime from its UTF-8 encoding spelled byte-by-byte in octal, one variable per icon, each with the glyph name and codepoint in a trailing comment so a human can map byte sequence → glyph without rendering it.

Shipped pattern in `home/dot_local/bin/executable_herdr-pane-labels:33-41`:

```bash
# Codicon glyphs of the $git_ref grammar, generated from bash 3.2-safe octal
# UTF-8 sequences (printf understands \NNN octal but not \uXXXX). Raw PUA
# glyphs are easily lost when the file passes through editors or agents, so
# none may appear verbatim in this script.
ICON_BRANCH="$(printf '\356\261\257')"   # nf-cod-git_branch U+EC6F
ICON_WORKTREE="$(printf '\356\261\276')" # nf-cod-worktree U+EC7E
ICON_COMMIT="$(printf '\356\253\274')"   # nf-cod-git_commit U+EAFC
ICON_FOLDER="$(printf '\356\252\203')"   # nf-cod-folder U+EA83
ICON_STALE="$(printf '\356\252\202')"    # nf-cod-history U+EA82
```

The formatter `git_ref_for()` (same script, line 755) consumes these variables in its branch/worktree/commit/folder/stale arms; nothing downstream ever touches a raw glyph.

**Single-source the table for generation — not for the test that protects it.** The rule above covers anything that *produces* a glyph: never retype the octal sequence, always read it from this one table. A *test asserting the glyph is correct* is a different consumer with the opposite requirement — if it derives its expected value from the same table, a drifted glyph can never fail it, because the assertion then compares the engine against itself.

**This distinction is currently unenforced in the harness, and the enforcement was reverted.** `tests/helpers/herdr_pane_labels.bash:19-24` defines `hpl_icon()`, a `sed`-extraction that reads each octal sequence out of the engine and re-expands it into `HPL_ICON_*`. The 29 `HPL_ICON_*` assertions in `tests/bashunit/scripts_test.sh` therefore compare the engine against itself and cannot fail on glyph drift. The helper's own comment states the reasoning backwards — "retyping it here would let an engine codepoint change pass while the suite still asserted the old bytes" — which is the argument for a *generator*, applied to an *oracle*.

The fix once landed and was undone: PR #140 removed the extraction, with the finding that "temporarily changing `ICON_BRANCH` in the engine now fails 19 previously-passing assertions." Seven hours later the `herdr-task-sync` → `herdr-pane-labels` rename carried the extraction forward as `hpl_icon()`, reverting it. Both tracking issues (`2026-08-20-007`, `2026-09-02-005`) were removed in the closed-issue cleanup, so the discriminator's evidence trail survives only in git history.

**What still holds the line.** `tests/bashunit/smoke_test.sh:952-957` pins the five octal sequences as independent literals and then asserts the raw lead byte is absent from the engine:

```bash
assert_file_contains "$engine" '\\356\\261\\257' # nf-cod-git_branch U+EC6F
# ... four more ...
run env LC_ALL=C grep -n "$(printf '\356')" "$engine" "$config"
assert_failure
```

That is a genuine independent oracle, but it covers five literals rather than the 29 formatter assertions PR #140 had made honest.

To derive the octal bytes for a new icon:

```bash
python3 -c "print(''.join('\\%o' % b for b in chr(0xEC6F).encode('utf-8')))"
# \356\261\257
```

Verify the round trip: `printf '\356\261\257' | xxd` → `ee b1 af`, the UTF-8 encoding of U+EC6F. Works for 4-byte codepoints above the BMP the same way.

## Why This Matters

- A pasted glyph that a formatter, agent, or copy-paste hop replaces with U+FFFD ships a broken icon that no diff reviewer can see — both versions render as the same tofu box. The live incident above (session history) is exactly this: the loss showed up only when a human looked at the rendered pane.
- The tempting spelling `printf '\uEC6F'` silently prints the literal six characters `\uEC6F` under bash 3.2 rather than erroring, so the bug appears only as garbage in the TUI.
- Octal escapes are pure ASCII: stable through every editor, agent, diff, and normalization pass, and greppable and reviewable byte-for-byte.

## When to Apply

- Any script emitting Nerd Font / PUA glyphs that must run under macOS system bash 3.2 (or `sh`): herdr hooks, tmux and sketchybar configs, prompt scripts.
- More generally: whenever a source file must carry bytes that editors cannot display faithfully, spell the bytes — don't paste them.
- This is the unicode-specific instance of the standing environment rule that macOS system bash is 3.2 (no `declare -A`, and no `\uXXXX` printf escapes).
- Not needed where bash ≥ 4.2 is guaranteed (`\uXXXX` works) or the file format is binary-safe by design.
- Width-math sibling gotcha, handled directly below the icon table in the same script: `wc -m` and `cut -c` must run under a UTF-8 locale, or each 3-byte codicon counts as three columns and truncation can cut a label mid-codepoint (`executable_herdr-pane-labels:42-57`).

## Examples

- `home/dot_local/bin/executable_herdr-pane-labels:33-41` (icon table), `:755` (`git_ref_for()` consumer), `:42-57` (locale pin for width math).
- `tests/helpers/herdr_pane_labels.bash:14-34` (`HPL_ICON_*` re-derived from the engine via `hpl_icon()` — the circularity described in the Guidance discriminator above, not an independent pin); icon-asserting tests in `tests/bashunit/scripts_test.sh` include "herdr-pane-labels location and formatter add only approved static icon glyphs and no forbidden ownership state", which strips the five codicons and asserts only plain ASCII remains.
- Decision origin: `docs/plans/2026-08-20-001-feat-herdr-label-system-plan.md`, "Icon set — DECIDED" — records the codicon choice per slot, the octal sequences, the material-icons fallback family, and the "PUA glyph loss" risk entry.
- Commits: `f7fd73c` (branch-first tab labels), `7c868d6` (unified `$git_ref` token), `9d1895f` (PR #24 close-out). All reachable from main.

## Related

- `2026-08-20-007` — the hand-duplicated icon table defect and its single-source resolution.
- `docs/plans/2026-08-20-001-feat-herdr-label-system-plan.md` — origin plan of the label system.
- `CONCEPTS.md` Theming section — the sibling terminal-rendering convention (palette-only, no baked hex); complementary, does not cover glyph encoding.
- `2026-09-02-005` — the discriminator between single-sourcing for generation and pinning literals
  for a test whose job is to catch a change to the glyph itself.
- Closed issues above are bare IDs, for archaeology in git history: `2026-08-20-007`, `2026-09-02-005`.
  Both files were removed in the closed-issue cleanup; the evidence they carried is reproduced inline above.
