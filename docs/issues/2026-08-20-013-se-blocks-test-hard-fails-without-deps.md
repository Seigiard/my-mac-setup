---
title: se blocks test hard-fails on a fresh checkout instead of skipping
type: bug
date: 2026-08-20
status: done
closed: 2026-08-20
---

## Why this exists

On a fresh checkout `bats tests/scripts.bats` reports one failure:

```
not ok 186 se blocks --json emits the composable block catalog
# se: smithers binary not found:
#   home/private_dot_claude/dot_smithers/./node_modules/.bin/smithers
#   (run bun install in home/private_dot_claude/dot_smithers)
```

The test at tests/scripts.bats:4815 drives the real `se` binary, which only exists
after `bun install` in `home/private_dot_claude/dot_smithers`. Every other test in
the suite that needs an absent tool skips instead of failing -- `jq`, `bun`,
`python3`, the repo-root Makefile. This one did not, so a fresh clone reports a red
suite for a missing optional dependency rather than a real defect.

## Correction to the original filing

This issue was first filed as "node_modules is not gitignored". **That was wrong.**
`node_modules/` is already ignored, by the nested
`home/private_dot_claude/dot_smithers/.gitignore:1`, and the chezmoi side is covered
too by the `.claude/.smithers/node_modules` rules in `home/.chezmoiignore`.

The original check was a false negative: `git check-ignore` was given
`.../dot_smithers/node_modules` with no trailing slash while the directory did not
exist on disk, and the pattern `node_modules/` matches directories only. With a
trailing slash, or against any path inside it, the same command reports the match.

Nothing in `.gitignore` needed changing.

## Scope

- Guard the test the way the rest of the suite guards on missing tools.

## Resolution

Added the suite's standard guard to tests/scripts.bats:4815:

```
[ -x "$smithers_dir/node_modules/.bin/smithers" ] || \
  skip "smithers deps not installed (run bun install in $smithers_dir)"
```

This cannot hide a broken install in CI. The workflow installs the dependencies
with `bun install --frozen-lockfile` and then asserts the binary is executable in a
separate step (`.github/workflows/test-dotfiles.yml:96-102` for ubuntu and
`:147-152` for macos), so an install failure fails the job before the suite runs.

Verified: on this machine, with the dependencies absent, the test now reports
`ok ... # skip smithers deps not installed`, and the local suite has no failures.
