---
title: "update-all checks pinned versions and offers bumps"
short_description: "After the pinned-externals migration (plan 2026-09-05-0906), update-all in home/dot_aliases should compare the pinned chezmoi-external refs (Oh My Zsh, four zsh plugins, fff-mcp) and mise tool versions against upstream and offer each bump interactively (y/n), replacing the removed omz update call."
type: "follow-up"
category: "dotfiles"
tags: ["update-all","externals","mise"]
date: "2026-09-05"
status: "done"
priority: "medium"
closed: "2026-09-05"
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

## Resolution

Implemented as a new helper, home/dot_local/bin/executable_update-pins, which update-all now calls after mise upgrade.

The helper walks three pin families. The five /archive/<sha>.tar.gz externals compare against the upstream default branch HEAD via git ls-remote; fff-mcp compares its release tag against the releases/latest redirect; mise tools come from mise outdated --bump, which leaves a moving alias such as the repo's node = "lts" alone because it carries no pin to rewrite. No GitHub REST API is used, so there is no token and no rate limit. The archive inventory is parsed out of .chezmoiexternal.toml rather than hardcoded, so adding or removing a pin needs no edit to the script.

Every accepted bump edits the chezmoi source tree, located through chezmoi source-path with a .chezmoiroot fallback, never a live file under ~/. Writes go through one atomic rewrite that requires each replaced literal to occur exactly once and preserves the file mode. Declining is the default ([y/N]) and writes nothing. An accepted fff-mcp bump fetches all four per-platform sha256 values before writing anything; one failed fetch aborts the whole bump and prints the values a manual bump would need, so a stale checksum can never sit beside a bumped tag. An unreachable upstream reports that pin as unknown and continues, so update-all does not appear to fail when GitHub is down.

Verified by the orchestrator rather than taken on report: make lint exit 0, make test-issues exit 0, and tests/bashunit/scripts_test.sh 352 passed / 1 skipped / 0 failed. The six new tests (1451-1456) drive the script against a fixture copy of the repository's real pinned files with the network replaced by a stub fetcher, and assert resulting bytes. Two mutations confirm they can fail: making confirm always accept turns 5 of the 6 red, and disabling the all-or-nothing checksum abort turns exactly the abort test red.

Not verified: make test-local could not run. A chezmoi apply started from the user's own interactive shell (PID 92614) holds the persistent state lock, and it was left alone rather than killed. The helper is a plain script with no .tmpl suffix, so it carries no template-rendering risk, but it is a new managed path and therefore deployment-sensitive; make test-ubuntu covers it at the end of the sweep.
