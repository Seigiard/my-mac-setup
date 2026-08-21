---
title: "Install Smithers dependencies before post-apply GitHub CI tests"
short_description: "Install Smithers dependencies before post-apply GitHub CI tests"
type: "bug"
category: "testing-ci"
tags: ["testing-ci","bug"]
date: "2026-08-18"
status: "done"
priority: "critical"
closed: "2026-08-21"
---

## Why this exists

The `Test Dotfiles` GitHub Actions workflow is red on `main` and on pull requests because post-apply tests execute Smithers commands without the required runtime dependencies.

The current `main` run `32147357598` at commit `d09ac094e02afb3a6a80163fea3a4763186e2cbc` reproduces the failure:

- Ubuntu job `95744283019` fails five `se flow` tests with `bun: command not found`.
- The same Ubuntu job fails `se blocks --json emits the composable block catalog` because `home/private_dot_claude/dot_smithers/node_modules/.bin/smithers` does not exist.
- macOS job `95744282862` fails the same block-catalog test because the source-tree Smithers binary does not exist.

Pull request #13 reproduces the same baseline failure in run `32148591922`:

- Ubuntu job `95748455289` fails six tests.
- macOS job `95748455290` fails one test.

`home/.chezmoiscripts/run_onchange_after_4-install-smithers-deps.sh.tmpl` installs dependencies only in the deployed runtime directory at `~/.claude/.smithers`. It exits successfully without installing anything when `bun` is absent. The tests invoke `home/private_dot_claude/dot_smithers/bin/executable_se` from the checkout, whose default Smithers directory is the adjacent source directory. GitHub CI does not install dependencies there.

Local `make test-ubuntu` passes when the source-tree Smithers directory has `node_modules`, which confirms that the dependency gap causes the CI failures rather than the child-agent contract changes in pull request #13.

## Scope

- Make `bun` available before tests that execute `se flow` on Ubuntu and macOS.
- Install the locked Smithers dependencies in the directory that checkout-based tests use.
- Keep runtime deployment tests separate from source-checkout command tests.
- Ensure the workflow uses `bun install --frozen-lockfile`.
- Add a preflight assertion that reports the missing dependency once, before dependent tests run.
- Verify both GitHub Actions jobs against the default branch.

## Open decisions

- Should GitHub CI install source-tree Smithers dependencies directly, or should tests point `SE_SMITHERS_DIR` at the deployed runtime directory?
- Should the workflow cache Bun packages or `node_modules`, and which lockfile hash should key that cache?
- Should tests that only validate command composition use a stub validator so they do not require the full Smithers install?

## Resolution

Commit `399d8e0105ef698a2c090fb858ae6a509bf99b51` fixed the GitHub Actions dependency gap by installing Bun before apply, installing the locked Smithers dependencies directly in the source tree with `bun install --frozen-lockfile`, and adding a preflight for both source-tree and deployed-runtime Smithers binaries.

Default-branch `Test Dotfiles` run `32504078129` (https://github.com/Seigiard/my-mac-setup/actions/runs/32504078129) passed at the current `main` tip, `db9cb20ed1d867f3bda4ebbfbc53522a1ae43508`. Ubuntu job `96840269094` and macOS job `96840269336` both passed `Install bun`, `Install smithers dependencies in the source tree`, `Test the Smithers issue writer`, `Verify both smithers directories the tests call`, and `Run post-apply tests`. The run therefore proves that neither `bun: command not found` nor the missing source-tree Smithers binary still reproduces.

The original decisions are settled as follows: continuous integration installs source-tree Smithers dependencies directly; dependency caching remains unnecessary for correctness; and a stub validator remains outside this closure because the real Smithers dependency path now passes on both operating systems.
