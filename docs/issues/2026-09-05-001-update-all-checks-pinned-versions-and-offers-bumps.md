---
title: "update-all checks pinned versions and offers bumps"
short_description: "After the pinned-externals migration (plan 2026-09-05-0906), update-all in home/dot_aliases should compare the pinned chezmoi-external refs (Oh My Zsh, four zsh plugins, fff-mcp) and mise tool versions against upstream and offer each bump interactively (y/n), replacing the removed omz update call."
type: "follow-up"
category: "dotfiles"
tags: ["update-all","externals","mise"]
date: "2026-09-05"
status: "open"
priority: "medium"
---

## Why this exists

The plan `docs/plans/2026-09-05-0906-refactor-mise-declarative-setup-plan.md` (KTD3/KTD4) pins Oh My Zsh, the four zsh plugins, and fff-mcp to fixed refs in `home/.chezmoiexternal.toml` and removes `omz update` from the `update-all` alias. After that lands, nothing updates these dependencies without a manual source edit, and nothing tells the owner an update exists. The owner chose pinning over auto-refresh on the condition that `update-all` grows a guided bump path.

## Scope

Extend `update-all` in `home/dot_aliases` (or a helper script it calls) to:

- compare each pinned external ref (OMZ, zsh-autosuggestions, fast-syntax-highlighting, zsh-history-substring-search, zsh-defer, fff-mcp) against the upstream latest release or HEAD;
- compare mise tool versions against `mise outdated`;
- for each available update, show current → latest and offer the bump interactively (y/n);
- an accepted bump edits the repo source (`home/.chezmoiexternal.toml` ref, or the mise config), never the live files, preserving the versions-change-only-via-source convention.

Out of scope: auto-applying bumps, CI integration.

## Open decisions

- Whether a bump also fetches and updates the fff-mcp per-platform sha256 values automatically (four checksums per bump) or prints them for manual entry.
