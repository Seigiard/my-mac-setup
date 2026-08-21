---
title: "Uncapped repo name in a multi-repo tab prefix breaks the 80-column label budget"
short_description: "Uncapped repo name in a multi-repo tab prefix breaks the 80-column label budget"
type: "bug"
category: "repository-maintenance"
tags: ["repository-maintenance","bug"]
date: "2026-08-20"
status: "done"
priority: "low"
parent-plan: "docs/plans/2026-08-20-001-feat-herdr-label-system-plan.md"
closed: "2026-08-20"
---

## Why this exists

`home/dot_local/bin/executable_herdr-task-sync` composes a herdr tab label from
per-pane segments. When a tab spans more than one repository, the composer
prepends the repository name to each segment prefix:

- `home/dot_local/bin/executable_herdr-task-sync:1444-1445` (the two-pane path)
- `home/dot_local/bin/executable_herdr-task-sync:1452-1453` (the three-or-more-pane path)

The branch ref beside it is capped at `WORKTREE_TOKEN_MAX_LEN` (18) by
`truncate_text` at line 1344. The repository name is spliced in with no cap.

`compose_two_mixed_segments` (lines 957-987) only ever shrinks the two pane
texts to fit `LABEL_COLUMNS=80`; it never shrinks a prefix. Its per-pane budgets
floor at `min(8, length)`, so when `available` goes negative the loop that
distributes `extra` never runs and the function still emits both prefixes plus
16 columns of text.

Measured by extracting `text_length`, `text_prefix`, `truncate_text`, and
`compose_two_mixed_segments` into a scratch script and calling them directly:

| Repo names | Measured columns |
|---|---|
| `a`, `b` (what the suite uses) | 47 |
| `my-mac-setup`, `integration-app` | 90 |
| `membrane-platform`, `integration-app-web` | 99 |
| `integration-platform-connectors`, `internal-developer-tooling-workspace` | 108 |

The existing 80-column assertions in `tests/scripts.bats` all use a single
shared repository, so `multiple_repos` stays 0 and the repo-prefix path is never
measured. The only multi-repo test uses single-character repository names.

Found by three independent reviewers (correctness, testing, adversarial) plus an
external cross-model review leg, and confirmed by an independent validation pass.

## Scope

- Cap the repo token where it is spliced, with the helper already used one line
  above for the ref: `truncate_text "$repo_one" "$WORKTREE_TOKEN_MAX_LEN"` at
  1444-1445, and `truncate_text "$segment_repo" "$WORKTREE_TOKEN_MAX_LEN"` at
  1453.
- Capping alone still admits roughly 99 columns worst case, so also floor the
  budget inside `compose_two_mixed_segments`: when `fixed` exceeds
  `LABEL_COLUMNS`, shrink the pane texts (or the prefixes) instead of emitting
  an over-budget label.
- Add a bats case with two realistic repository names and two near-cap branch
  names, asserting the label stays within `LABEL_COLUMNS`. Mirror the existing
  single-repo 80-column assertion.

## Open decisions

- Truncate the repository name with an ellipsis, or drop the repo token entirely
  when it does not fit? Truncation keeps the disambiguation the token exists for;
  dropping keeps the label clean but reintroduces the ambiguity of two
  same-shaped segments.
- Whether `WORKTREE_TOKEN_MAX_LEN` is the right cap for a repository name, or
  whether the repo token deserves its own shorter constant. The same constant now
  serves three concepts: worktree tokens, tab-segment refs, and (under this fix)
  repository names.

## Resolution

Fixed in commit 9e69d0b. The repo name is capped where it is spliced, but with
its own constant rather than `WORKTREE_TOKEN_MAX_LEN`: `REPO_TOKEN_MAX_LEN=12`,
applied with ellipsis truncation by the new `repo_qualified_prefix` helper that
both tab branches route through. `compose_two_mixed_segments` additionally
shrinks its per-pane floors when the prefixes leave less room than the
eight-column floors ask for, so it never emits a label past the budget. Both
open decisions resolved: truncation over dropping (keeps the disambiguation),
and a dedicated shorter constant for the repo token. Covered by the bats case
"two-pane mixed formatter caps repo names so a multi-repo tab holds the
80-column budget" with two realistic repo names and near-cap branch names.
