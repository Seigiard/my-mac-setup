---
status: done
---

# Herdr Label System — branch-first `$git_ref` grammar

Design and implementation plan for Herdr tab labels, pane labels, and agent-sidebar rows.
Base: commit `93dd91d` (branch-first tab labels experiment) on `main`.
Published copy: https://claude.ai/code/artifact/d94bdedd-b60c-4207-ba56-160482ffbcc8

## Design principle

Every token must earn its place. **Branch is the primary text**; whether the pane sits
in the main checkout or a linked worktree is carried by the **icon**, not by a second
word; the worktree **folder appears only when it disagrees** with both the branch and
the workspace name.

This replaces the folder-first grammar, where the Git row collapsed to a single token
whenever folder and branch coincided, and where the folder duplicated the workspace
name for every main-checkout pane. In the new grammar the row skeleton is constant:
*icon + ref*, with an optional qualifier.

## The `$git_ref` token

One formatter produces one token used on every surface:

```
$git_ref = <place-icon> <ref> [ <folder-icon> <folder>] [<status-icon>]
```

| Slot | Rule |
|---|---|
| place-icon | branch icon = main checkout on a branch; worktree icon = linked worktree; commit icon = detached HEAD |
| ref | branch name when on a branch; 7-char short SHA when detached. Never the folder. |
| folder qualifier | folder icon + worktree token, only when worktree token ≠ branch **and** ≠ workspace name |
| status-icon | dim stale icon appended when `location_status = stale`; replaces the separate third sidebar row |

### Icon set — DECIDED (picked visually in live herdr rendering, 2026-08-20)

One consistent Nerd Font family — codicons:

| Slot | Glyph name | Codepoint | Char |
|---|---|---|---|
| branch | `nf-cod-git_branch` | U+EC6F |  — `printf '\356\261\257'` |
| worktree | `nf-cod-worktree` (full-size; `worktree_small` U+EC7D rejected) | U+EC7E |  — `printf '\356\261\276'` |
| commit (detached) | `nf-cod-git_commit` | U+EAFC |  — `printf '\356\253\274'` |
| folder | `nf-cod-folder` | U+EA83 |  — `printf '\356\252\203'` |
| stale | `nf-cod-history` | U+EA82 |  — `printf '\356\252\202'` |

Runner-up family kept as documented fallback if a codicon fails to render on another
machine: material (`nf-md-source_branch` U+F062C, `nf-md-source_fork` U+F04C1,
`nf-md-source_commit` U+F0718, `nf-md-folder_outline` U+F0256, `nf-md-history`
U+F02DA). Octicons and other families reviewed and rejected.

Note: PUA characters are easily lost when files pass through editors or agents.
Generate them in the script from the octal UTF-8 sequences above (bash 3.2 printf understands `\NNN` octal escapes but not `\uXXXX`); never
paste raw glyphs into the script.

### Main checkout vs linked worktree detection

A linked worktree has a `.git` **file** at its root; the main checkout has a `.git`
**directory**. Zero-cost check inside the existing location resolver. Known caveat:
submodule roots also carry a `.git` file — accepted (an agent parked at a submodule
root genuinely is not in the main checkout); note it in a comment.

## Surfaces: one grammar, three renderings

Reading rule everywhere: **first part = identity of the work** (workspace + task),
**second part = where it lands** (`$git_ref`).

| Surface | Grammar |
|---|---|
| Agent sidebar | row 1: `state_icon workspace pane`; row 2: `$git_ref` |
| Tab label | `$git_ref · <pane> [· <pane>…]` when panes share a location; per-segment prefixes otherwise (see matrix rows 5–7) |
| Pane label | `cc:/oc:/pi:/cx:<slug>`, command name, or `~` — unchanged |

Pane labels stay task-only: a pane lives inside a tab that already carries the
location. The sidebar config drops from three rows to two — `$location_status` merges
into `$git_ref` as a suffix icon, which also shrinks the flicker surface.

Target config:

```toml
[ui.sidebar.agents]
rows = [["state_icon", "workspace", "pane"], ["$git_ref"]]
```

## Scenario matrix

Workspace is `my-mac-setup` unless stated. Icons shown as ⎇ (branch), ⑂ (worktree),
◉ (commit), 🗀 (folder) — real output uses the codicon codepoints above.

| # | Scenario | Sidebar row 2 | Tab label |
|---|---|---|---|
| 1 | Agent in repo root, branch `main` | `⎇ main` | `⎇ main · pi:task` |
| 2 | Worktree, folder == branch (`feature`) | `⑂ feature` | `⑂ feature · cc:task` |
| 3 | Worktree, folder ≠ branch (`wt-hotfix` on `fix-login`) | `⑂ fix-login 🗀 wt-hotfix` | `⑂ fix-login · cc:task` (folder lives in the sidebar only) |
| 4 | Detached HEAD at `a1b2c3d` | `◉ a1b2c3d` | `◉ a1b2c3d · cc:task` |
| 5 | Two panes, same branch + worktree | each: `⑂ feature` | `⑂ feature · cc:a · pi:b` (shared ref hoisted once) |
| 6 | Two panes, same repo, different worktrees | each pane's own ref | `⎇ main cc:a · ⑂ feature pi:b` (per-segment prefix, icon + ref only) |
| 7 | Two panes, different repos | each pane's own ref | `mms ⎇ main cc:a · iv ⎇ dev pi:b` (repo prefix only in this case) |
| 8 | Command pane, `foreground_cwd` ≠ `cwd` | Location follows `foreground_cwd` — strict foreground semantics kept for non-agent panes | — |
| 9 | Agent pane running a tool from a temp dir | Location follows stable `pane.cwd` — keep the existing anti-flicker behavior as-is | — |

## Resolved design decisions

1. **Branch vs worktree in tab identity** — branch is always the text; worktree-ness is
   the icon. No "which wins" question remains.
2. **Mixed-worktree tabs** — hoist the shared `$git_ref` once when all panes agree;
   otherwise each segment gets a compact icon+ref prefix (no folder qualifier inside
   tabs — the sidebar carries that detail).
3. **Herdr `pane` vs custom `$pane_inline`** — keep native `pane` in row 1. Revisit only
   if dimming/spacing control is needed.
4. **`location_status = stale` rendering** — dim suffix icon on `$git_ref`, not a
   separate row and not text. The `[stale]` text marker in tab labels is replaced by
   the same icon.
5. **Special cases** — detached HEAD → commit icon + short SHA; folder == branch →
   plain worktree case (the icon already says it); repo-root main checkout → branch
   icon + branch, with the folder qualifier suppressed in the typical case where the
   checkout folder repeats the branch or the workspace name. A main checkout in a
   differently-named folder keeps its folder qualifier — the same suppression rule
   as every other checkout, no main-checkout special arm. (Reworded per
   docs/issues/2026-08-20-007: the original "no folder ever" promised more than the
   implemented and now-tested rule delivers, and the implemented rule is the better
   one — a divergent folder name is real location information.)
6. **One location policy or two** — two, deliberately. Agent panes read `pane.cwd`
   (stable during tool calls); command panes read `foreground_cwd`. Already
   implemented and tested — do not regress.

## Implementation units

All edits are one coherent pass over the files already touched by `93dd91d`.

### U1 — Resolver: `is_linked` + detached SHA

`home/dot_local/bin/executable_herdr-task-sync`

- Add an `is_linked` flag to `resolve_pane_location` (`.git` file vs directory at the
  checkout root).
- When HEAD is detached (branch empty but repo present), capture the 7-char short SHA
  as the ref and mark the place as `detached`.
- Plumb both new fields through the pipeline field lists (the `FIELD_SEPARATOR`
  records in `reconcile_presentation_pass`).

### U2 — Formatter: single `git_ref_for`

Same file.

- Replace `location_label_for` and `tab_location_label_for` with one
  `git_ref_for(place, ref, folder, status)` implementing the grammar above.
- Define the icon table once near the top of the script, generated with the octal
  `printf` sequences from the icon-set table above, with the codicon names in a comment.
- Folder qualifier rule: emit only when worktree token ≠ ref and ≠ workspace name.

### U3 — Tab composer

Same file.

- Hoist-common / per-segment logic per matrix rows 5–7.
- Repo prefix only in the different-repos case (row 7).
- Replace the `[stale]` text marker with the stale suffix icon on the segment's ref.

### U4 — Config: two sidebar rows

`home/private_dot_config/herdr/config.toml`

- `rows = [["state_icon", "workspace", "pane"], ["$git_ref"]]` — remove
  `$location_status` and `$location_label` in favor of `$git_ref`.
- Re-check `sidebar_min_width = 32` against the longest matrix row
  (`⑂ fix-login 🗀 wt-hotfix` + stale icon).

### U5 — Tests

`tests/scripts.bats`, `tests/smoke.bats`

- One formatter test per scenario matrix row (9 cases).
- Update existing location, formatter, and pi-jsonl tests to the new token names.
- Smoke tests assert the two-row managed and deployed sidebar config.

### U6 — Rollout (user-driven tail)

- Commit → sync the chezmoi clone (`~/.local/share/chezmoi`, `git pull`) → the user
  runs `chezmoi apply` (never run it on the host from an agent).
- **Restart the sweep daemon** — replacing `~/.local/bin/herdr-task-sync` does not
  restart a running `--sweep-daemon`; a stale daemon keeps writing labels with the old
  logic.

## Verification gate

```bash
bash -n home/dot_local/bin/executable_herdr-task-sync
bats tests/scripts.bats
bats tests/smoke.bats
```

## Risks and standing constraints

- **Three copies of every file.** This checkout is not what chezmoi reads. Live files
  `~/.config/herdr/config.toml` and `~/.local/bin/herdr-task-sync` were edited directly
  during earlier experiments and can drift from both HEAD and the chezmoi clone until
  commit + apply.
- **Stale sweep daemon** — see U6.
- **PUA glyph loss** — see the icon-set note: never paste raw glyphs; generate from
  codepoints.
- **Submodule roots** read as linked worktrees. Accepted; noted in a comment.
- **Deferred by design:** dynamic branch-state icons (ahead/behind), color/dim styling
  beyond the stale suffix, custom `$pane_inline`.
