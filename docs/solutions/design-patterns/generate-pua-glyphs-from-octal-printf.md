---
title: Generate PUA glyphs from octal printf — never paste them
date: 2026-08-21
category: design-patterns
module: shell-portability
problem_type: design_pattern
component: tooling
severity: medium
related_components:
  - development_workflow
applies_when:
  - "Adding or changing PUA glyph generation in a repository-owned shell script that must run under macOS bash 3.2"
  - "Reviewing the encoding of a PUA glyph in repository-owned shell source"
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
2. **macOS ships bash 3.2** (the GPLv2 freeze). A script that uses that interpreter cannot rely on `printf` supporting `\uXXXX` Unicode escapes; it does support `\NNN` octal byte escapes.

The failure was hit live during icon selection for the Herdr label system on 2026-08-20: a glyph-candidate card lost most of its pasted icons on file write. It worked after regeneration from codepoints. That incident is the precedent for this encoding rule.

## Ownership

The pane-label engine and its glyph tests belong to
[`Seigiard/herdr-pane-labels`](https://github.com/Seigiard/herdr-pane-labels), following
the extraction in [#298](https://github.com/Seigiard/my-mac-setup/pull/298).
This repository installs that package; it does not own its icon table or test harness.
Changes to the package's glyphs belong upstream.

This document keeps the general generation rule for new repository-owned shell code.
Installing or updating the external package alone does not trigger it or justify a local
test of the upstream source encoding.

## Guidance

Never paste a PUA glyph literally into a script. Generate it at runtime from its UTF-8 encoding spelled byte-by-byte in octal, one variable per icon, each with the glyph name and codepoint in a trailing comment so a human can map byte sequence → glyph without rendering it.

Example using Codicon codepoints, not a pointer to a local engine:

```bash
# Bash 3.2-safe UTF-8 bytes. Keep source ASCII; name each glyph for review.
ICON_BRANCH="$(printf '\356\261\257')"   # nf-cod-git_branch U+EC6F
ICON_WORKTREE="$(printf '\356\261\276')" # nf-cod-worktree U+EC7E
ICON_COMMIT="$(printf '\356\253\274')"   # nf-cod-git_commit U+EAFC
ICON_FOLDER="$(printf '\356\252\203')"   # nf-cod-folder U+EA83
ICON_STALE="$(printf '\356\252\202')"    # nf-cod-history U+EA82
```

Formatters consume the variables rather than repeating the byte sequences.

**Single-source the table for generation — not for the test that protects it.** The rule above covers anything that *produces* a glyph: never retype the octal sequence, always read it from this one table. A *test asserting the glyph is correct* is a different consumer with the opposite requirement — if it derives its expected value from the same table, a drifted glyph can never fail it, because the assertion then compares the engine against itself.

**Historical test lesson.** Before extraction, the local harness read expected glyphs
from the engine's own table. A wrong codepoint changed both sides and stayed green.
[PR #140](https://github.com/Seigiard/my-mac-setup/pull/140) replaced that extraction;
changing the engine's branch icon then failed 19 assertions. A later rename restored
the mistake, and [PR #179](https://github.com/Seigiard/my-mac-setup/pull/179)
removed it again. The harness and its mutation check later moved out with the engine.

The remaining local source-encoding pin was retired in
[PR #349](https://github.com/Seigiard/my-mac-setup/pull/349). Do not recreate that pin
here: use the test-oracle gate for repository-owned behavior, and test upstream glyph
semantics in the upstream package.

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

- Repository-owned shell code emitting Nerd Font / PUA glyphs under macOS system bash 3.2.
- More generally: whenever a source file must carry bytes that editors cannot display faithfully, spell the bytes — don't paste them.
- This is the unicode-specific instance of the standing environment rule that macOS system bash is 3.2 (no `declare -A`, and no `\uXXXX` printf escapes).
- If the target interpreter or template format supports Unicode escapes, those are another way to keep source ASCII. Do not impose shell byte-escape syntax on another file format.
- Character-based width and truncation need a UTF-8 locale. Byte length, codepoint count, and terminal display width are different measures; an icon's UTF-8 byte count is not its column width.

## Examples

- Current pane-label implementation and glyph tests: [`Seigiard/herdr-pane-labels`](https://github.com/Seigiard/herdr-pane-labels).
- Decision origin: `docs/plans/2026-08-20-001-feat-herdr-label-system-plan.md`, "Icon set — DECIDED" — records the codicon choice per slot, the octal sequences, the material-icons fallback family, and the "PUA glyph loss" risk entry.

## Related

- `2026-08-20-007` — the hand-duplicated icon table defect and its single-source resolution.
- `docs/plans/2026-08-20-001-feat-herdr-label-system-plan.md` — origin plan of the label system.
- `CONCEPTS.md` Theming section — the sibling terminal-rendering convention (palette-only, no baked hex); complementary, does not cover glyph encoding.
- `semantic-regression-tests-over-source-shape.md` — the test-oracle gate for locally owned behavior.
- `2026-09-02-005` — the discriminator between single-sourcing for generation and pinning literals
  for a test whose job is to catch a change to the glyph itself; resolved in `5d7c8fc` (PR #179).
- Closed issues above are bare IDs, for archaeology in git history: `2026-08-20-007`, `2026-09-02-005`.
  Both files were removed in the closed-issue cleanup; the evidence they carried is reproduced inline above.
