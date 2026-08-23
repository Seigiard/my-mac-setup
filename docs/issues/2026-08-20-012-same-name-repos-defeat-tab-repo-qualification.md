---
title: "Two repositories with the same folder name defeat the multi-repo tab qualifier"
short_description: "Names-only Herdr tab labels removed repository qualifiers, so same-name and truncation collisions can no longer affect tab identity."
type: "bug"
category: "herdr"
tags: ["herdr","tab-labels"]
date: "2026-08-20"
status: "done"
priority: "low"
parent-plan: "docs/plans/2026-08-20-001-feat-herdr-label-system-plan.md"
closed: "2026-08-23"
---

## Why this exists

The multi-repo tab qualifier in `home/dot_local/bin/executable_herdr-task-sync`
identifies a repository by its folder basename only: `repository_name` (line
634) returns the last path component of the repository anchor. Two failure
modes follow, both verified against the code on main.

**Mode 1 — the qualifier never fires.** `compose_tab_intents` decides that a
tab spans multiple repositories by comparing repo-name strings: at lines
1180-1186, `multiple_repos` is set only when a later pane's `_repo` differs
from `first_repo`. Two distinct repositories that share a folder name (for
example `~/work/app` and `~/oss/app`) produce the identical string `app`, so
`multiple_repos` stays 0 and no repo prefix is added at all. The tab shows two
same-shaped segments with no disambiguation — the exact ambiguity the
qualifier exists to remove, silently skipped in the one case where the names
collide.

**Mode 2 — the qualifier fires but is identical.** When a third,
differently-named repo makes `multiple_repos=1`, each prefix is built by
`repo_qualified_prefix` (line 976), which truncates the name to
`REPO_TOKEN_MAX_LEN=12` with an ellipsis. Two repos distinct only after
character 11 (for example `integration-app-web` and `integration-app-api`)
both render as `integration…`, so their segments carry identical qualifiers.

Impact is cosmetic and bounded: a wrong-shaped label, never an over-budget one
and never a crash. The trigger needs same-named or long-prefix-sharing repos
open in one tab, which is uncommon but realistic (fork + upstream checked out
side by side share a basename by default).

The contrast worth noting: the same script already solves this exact problem
for worktree tokens. `build_worktree_tokens` (line 836) disambiguates
same-basename roots with a shortest-unique-suffix chain and a digest fallback.
Repo qualification predates none of that machinery — it simply does not use it.

Found by the external review legs during the label-system merge; deferred
there as a decision rather than a mechanical fix.

## Scope

- Base the `multiple_repos` decision on identity, not display name: compare
  `_repository_anchor` (or `_checkout_root`) instead of `_repo` at lines
  1180-1186. This fixes mode 1 with a one-line change and no new machinery.
- For the display collision (both modes), either route repo tokens through the
  same unique-suffix logic `build_worktree_tokens` uses, or accept identical
  qualifiers as a documented limitation once mode 1 is fixed (the qualifier
  then at least always appears when repos genuinely differ).
- Add a bats case: one tab, two panes from two distinct repositories whose
  folders share a basename, asserting the label distinguishes the segments (or
  documenting the accepted rendering if the display fix is declined).

## Open decisions

- How much of `build_worktree_tokens` to reuse for repo display names.
  Full-path suffixes as repo qualifiers get long fast against
  `REPO_TOKEN_MAX_LEN=12`; a cheaper option is suffixing a short digest only
  on collision.
- Whether mode 2 alone (truncation collision with genuinely different names)
  is worth fixing, or only mode 1 (qualifier skipped entirely).

## Resolution

Superseded by names-only Herdr tab labels: repository qualifiers and Git prefixes were removed from tab composition; Git identity remains in the sidebar metadata.
