---
title: "Define contracts for inventory and literal tests"
short_description: "The audit's seven confirmed dependent oracles are now split across four implementation issues (2026-09-02-002 through 2026-09-02-005); this issue remains the registry of the shared rule and closes when all four land."
type: "follow-up"
category: "testing-ci"
tags: ["semantic-testing","source-ownership","literal-contracts"]
date: "2026-09-01"
status: "open"
priority: "medium"
---

## Why this exists

The 2026-09-01 test audit removed source-copy assertions only where behavioral or deployment owners already existed. A repository-wide follow-up audit then confirmed seven dependent oracles. Each can stay green while its consumer-visible behavior breaks, or fail after a harmless source refactor.

The shared rule they violate: architecture inventory tests and exact literals are valid only when they compare independent sides of a relationship, or protect a literal consumed outside the repository.

## Scope

This issue owns the rule and the split, not the code. The seven findings are implemented under four children:

- `2026-09-02-002` — CI cache event policy (`tests/test_ci_workflow.py:65-100`), post-apply suite inventory (`tests/test_post_apply_suite_contract.py:17-58`), and suppressed Docker failure (`tests/test_docker_contract.py:70-94`).
- `2026-09-02-003` — onchange template hash (`tests/bashunit/smoke_test.sh:956-968`) and palette fallback parser fixture (`tests/bashunit/palette_test.sh:527-555`).
- `2026-09-02-004` — Git ignore behavior (`tests/test_issues.py:517-521`) and Bats assertion checker reachability (`tests/test_bats_assertion_contract.py:128-136`).
- `2026-09-02-005` — Herdr task-sync glyphs (`tests/helpers/herdr_task_sync.bash:12-34`).

Across all four: keep and document externally consumed command, transport, schema, symlink, and rendered-config literals, and keep exactly one behavioral, deployment, or validation owner per contract. Safe deletions belong to `2026-09-01-003`; Pi hook and updater coverage gaps belong to `2026-09-01-004`; updater failure notifications belong to `2026-08-21-022`.

Close this issue once the four children are closed and no further dependent oracle remains from the audit list.

## Open decisions

**Settled.** A deployment assertion in the smoke or template suites is legitimate machine-setup policy when it fits one of two independent-oracle shapes; otherwise it is a source-shape mirror that should be strengthened or deleted.

1. **Literal consumed outside the repository.** The exact text is parsed verbatim by a tool this repo does not own and cannot invoke cheaply in CI — herdr's own TOML config parser, Pi's/OpenCode's directory-based module loader, Claude Code's hook runner. There is no cheaper oracle available, so the literal (or, better, the mechanism that consumes it) is the assertion. Kept, now documented at each site: `test_smoke_006` and `test_smoke_010` (herdr TOML keys herdr's parser reads at startup), `test_smoke_009` (herdr's trusted-owners allowlist — also fixed to read the deployed `$HOME` copy instead of `$SOURCE_ROOT`, which had made it a source-shape check wearing a deployment test's name), and `test_smoke_015` (Pi's `APPEND_SYSTEM.md` filename convention, which — unlike Claude's and OpenCode's adapters — has no separate settings.json toggle to check instead).
2. **Cross-reference between two independently maintained sides.** Neither side is copied from the other by the same change, so they can only agree by actually staying in sync. `test_smoke_022` replaced its hand-copied list of `~/.claude/shared/*.md` filenames with a two-directional check: every `~/.claude/shared/*.md` pointer written in a deployed skill, agent, or `CLAUDE.md` must resolve to a real file (forward — catches a renamed or deleted shared file), and every deployed shared file except the directory's own README index must be reachable from at least one such pointer (reverse — catches an orphaned file nothing loads).

Neither shape is "the deployed file matches its rendered source" — that check fires on an unrelated, unapplied checkout and stays out of scope by design (see `docs/solutions/design-patterns/semantic-regression-tests-over-source-shape.md`).

An assertion that fits neither shape — no external tool consumes the exact text, and nothing outside the test itself would notice a silent drift from reality — proves nothing and does not earn a slot just to keep a count up:

- **A cheap real consumer exists → exercise it directly.** `test_smoke_061` now runs the deployed Claude Code hook the same way `settings.json` invokes it and asserts the silent, exit-0 contract its own header comment already commits to, instead of checking existence and the execute bit (Claude Code always invokes it through `bash`, so the execute bit was never load-bearing). `test_smoke_063`, `test_smoke_065`, and `test_smoke_067` now dynamically import the deployed Pi extension, Pi brew-updater extension, and OpenCode plugin the same way each host's directory-based loader would, and assert the export shape the loader requires — catching a truncated or malformed deployed copy that bare `assert_file_exists` could not.
- **No consumer can be named → delete.** `test_smoke_021`'s check that `writing-for-agents/SKILL.md` contains the phrase `'vendored under its MIT License'` protected prose nothing reads programmatically; a search of `scripts/` and `docs/` for `vendored` found nothing depending on that exact wording, so the assertion was removed rather than kept for its own sake.

Every replacement above carries a mutation proof: the regression it should catch was reproduced against the real deployed `$HOME`, the test was rerun and observed red, then the file was restored and reverified green.

This settles the repository-wide answer this issue asked for. The four child issues still own their own findings.
