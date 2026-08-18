---
title: Install Smithers dependencies before post-apply GitHub CI tests
type: bug
date: 2026-08-18
status: open
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
