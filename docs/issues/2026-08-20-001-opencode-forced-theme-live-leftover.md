---
title: Live leftover ~/.config/opencode/themes/flexoki-light-forced.json fails smoke deployment contract
type: bug
date: 2026-08-20
status: done
closed: 2026-08-20
---

## Why this exists

`bats tests/smoke.bats --filter 'coding agents use terminal color palettes'` fails on
the live machine: `tests/smoke.bats:372` runs
`assert_file_not_exists "$HOME/.config/opencode/themes/flexoki-light-forced.json"`,
and that file still exists at `/Users/seigiard/.config/opencode/themes/flexoki-light-forced.json`.

The failure pre-exists the herdr label-system work: it reproduces with a clean stash
of the working tree at HEAD `93dd91d` (verified 2026-08-20 during the label-system
run). The forced theme was presumably retired from the managed source (removed or
renamed in `home/`), but the live copy was never cleaned up — `chezmoi apply` does not
delete it because the file is no longer managed (or a `.chezmoiremove` entry is
missing).

## Scope

- Decide the cleanup path: add the path to `home/.chezmoiremove`, or delete the live
  file manually and document it.
- Re-run `bats tests/smoke.bats --filter 'coding agents use terminal color palettes'`
  to confirm green.

## Open decisions

- Whether other retired opencode theme files linger live (check
  `~/.config/opencode/themes/` against `chezmoi managed`).

## Resolution

Took the declarative path: added
`.config/opencode/themes/flexoki-light-forced.json` to `home/.chezmoiremove`,
so `chezmoi apply` deletes the leftover on every machine that deployed the old
forced theme. Added a guard test in `tests/templates.bats`
(".chezmoiremove deletes the retired opencode forced theme"); the existing
".chezmoiremove entries are absent from the source tree" test confirms no
create/delete conflict.

Open decision checked: `~/.config/opencode/themes/` on the live machine
contains only `flexoki-light-forced.json`, and `chezmoi managed` lists no
files under that directory — no other retired theme files linger.

The live file stays in place until the user syncs the chezmoi source and runs
`chezmoi apply`; until then the smoke test
"coding agents use terminal color palettes" remains red on this machine, which
is expected.
