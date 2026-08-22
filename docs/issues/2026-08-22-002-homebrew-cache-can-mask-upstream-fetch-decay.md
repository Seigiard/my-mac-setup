---
title: "Homebrew cache can mask upstream fetch decay"
short_description: "The new GitHub Actions Homebrew downloads cache can let scheduled full-Brewfile runs reuse old bottle or cask archives instead of proving current upstream fetchability."
type: "follow-up"
category: "testing-ci"
tags: ["ci","homebrew","cache","verification"]
date: "2026-08-22"
status: "done"
priority: "medium"
parent-plan: "docs/plans/2026-08-22-0840-chore-homebrew-download-cache-plan.md"
closed: "2026-08-22"
---

## Why this exists

LFG review found that the U2 Homebrew downloads cache can weaken the full-Brewfile verification path.
The workflow comments state that scheduled and manual full-Brewfile runs catch upstream formula or cask decay.
The new cache steps run unconditionally on `schedule` and `workflow_dispatch`, so a successful full run can seed `downloads` with old bottle or cask archives.
A later full run can then pass from restored archives without proving that the current upstream archive is still fetchable.

This is not fixed in the U2 pull request because the obvious fixes change the product decision in `docs/plans/2026-08-20-2217-chore-ci-workflow-hygiene-plan.md`, KTD4.
Examples include disabling restore on full-verification events, using separate cache namespaces by event mode, or making scheduled full runs cache-save-only.

The same review pass also flagged cache-budget risk.
The rotating key intentionally creates a new immutable entry on every successful run, so PR runs can consume repository cache budget until GitHub eviction removes older entries.
The U2 plan keeps this as a measurement gate rather than adding workflow-side cache-size enforcement.

## Scope 

Decide the cache policy for full-Brewfile verification events.
The resolution must preserve one of these guarantees:

- scheduled or manual full-Brewfile runs prove current upstream fetchability for every installed archive;
- or the project explicitly accepts that full-Brewfile runs prove installability from a restored archive cache, not fresh upstream fetchability.

If fresh upstream fetchability remains required, change `.github/workflows/test-dotfiles.yml` so `schedule` and `workflow_dispatch` do not restore stale Homebrew downloads for the full verification path.
Also decide whether a workflow-side cache-size guard is needed, or whether the PR and post-merge measurement gate is enough.

## Open decisions

- Should `schedule` and `workflow_dispatch` skip Homebrew download restore, use a separate namespace, or keep the shared namespace from KTD4?
- Should the workflow enforce a size guard before cache save, or should the repository rely on GitHub cache eviction plus the U2 measurement gate?

## Resolution

Changed .github/workflows/test-dotfiles.yml so push and pull_request runs restore the Homebrew downloads cache, while schedule and workflow_dispatch full-Brewfile runs skip restore and save fresh downloads only after the job succeeds. Added tests/test_ci_workflow.py to keep full-Brewfile verification from restoring stale downloads, and included it in make test-issues via unittest discovery. Checked the current GitHub Actions Homebrew cache entries from PR #57: Linux and macOS total 216,808,319 bytes, which is below the 5 GB budget gate, so no workflow-side size guard was added.
