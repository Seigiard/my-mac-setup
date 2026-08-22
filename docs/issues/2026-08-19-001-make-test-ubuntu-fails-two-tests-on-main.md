---
title: "make test-ubuntu fails two tests on main because the Docker harness lacks two setup steps GitHub CI has"
short_description: "Docker now stages writable sibling home/tests copies and installs Smithers in a clean source copy, matching CI without depending on ignored host artifacts."
type: "bug"
category: "testing-ci"
tags: ["testing-ci","bug"]
date: "2026-08-19"
status: "done"
priority: "high"
closed: "2026-08-22"
---

## Why this exists

`make test-ubuntu` exits 2 on a pristine checkout of `main`. Two bats tests fail. Neither failure
appears in GitHub Actions, because the `test-ubuntu` job in `.github/workflows/test-dotfiles.yml`
performs two setup steps that `docker/docker-compose.yml` does not. The Docker suite is therefore
not a faithful local stand-in for CI, and anyone running it before pushing sees two red tests that
say nothing about their change.

Reproduce on `main`:

```
git archive origin/main | tar -x -C /tmp/main-check
cd /tmp/main-check && make test-ubuntu
```

Observed on `main` at commit `4ed3754`: 298 tests pass, these two fail.

### Failure 1 — `Pi brew auto updater focused tests pass`

`tests/smoke.bats:915` runs `bun test "$BATS_TEST_DIRNAME/pi-brew-auto-update.test.ts"`.
`tests/pi-brew-auto-update.test.ts:10` imports
`../home/dot_pi/agent/extensions/brew-auto-update/index.ts`.

That relative path assumes `tests/` and `home/` are siblings, which holds in the repo checkout and
in GitHub CI. `docker/docker-compose.yml:8-9` mounts them apart:

```
- ../home:/home/testuser/dotfiles:ro
- ../tests:/home/testuser/tests:ro
```

From `/home/testuser/tests`, `../home` resolves to `/home/testuser/home`, which does not exist. Bun
reports:

```
error: Cannot find module '../home/dot_pi/agent/extensions/brew-auto-update/index.ts'
       from '/home/testuser/tests/pi-brew-auto-update.test.ts'
```

### Failure 2 — `se blocks --json emits the composable block catalog`

`tests/scripts.bats:1797` asserts success, and `se` reports:

```
se: smithers binary not found:
/home/testuser/dotfiles/private_dot_claude/dot_smithers/./node_modules/.bin/smithers
(run bun install in /home/testuser/dotfiles/private_dot_claude/dot_smithers)
```

Nothing in the Docker harness provisions the source-tree copy of smithers. The GitHub `test-ubuntu`
job has an explicit step for exactly this, with a comment naming the same gap:

```
- name: Install smithers dependencies in the source tree
  working-directory: home/private_dot_claude/dot_smithers
  run: bun install --frozen-lockfile
```

Note that `docker/docker-compose.yml` mounts `../home` read-only, so a `bun install` cannot write
into the mount as it stands.

## Scope

Make `make test-ubuntu` agree with the GitHub `test-ubuntu` job, so a local red result means a real
regression.

- Give the test a source root it can resolve inside the container. Either mount `../home` at a path
  that keeps `tests/` and `home/` siblings, or have `tests/pi-brew-auto-update.test.ts` resolve the
  extension through the same `resolve_source_root` fallback chain that `tests/helpers/common.bash`
  already implements for bats.
- Provision the source-tree smithers dependencies inside the container, which requires the mount to
  be writable or the install to target the copy already made at
  `/home/testuser/.local/share/chezmoi`.
- Once both pass, decide whether the two setup steps belong in the compose file, the Dockerfile, or
  a shared script that both CI and Docker call, so the two harnesses cannot drift again.

## Open decisions

- Whether to fix the import path in the test or the mount layout in compose. Changing the mount
  affects every test that reads `$HOME/dotfiles`; changing the import affects one file.
- Whether the read-only `:ro` mount of `../home` is a deliberate guarantee worth keeping. If it is,
  the smithers dependencies must be installed into the chezmoi source copy instead.
- Whether `make test-ubuntu` should be gated in CI too, so this drift is caught automatically rather
  than by a developer running it locally.

## Resolution

Updated both Docker test services to copy the read-only home and tests mounts into a writable checkout-shaped worktree, remove copied Smithers node_modules, and run bun install --frozen-lockfile in that source tree before post-apply tests. This restores the sibling path required by the Pi TypeScript import, permits Python bytecode compilation, and prevents ignored host dependencies from masking missing Docker setup. The original Smithers failure had since gained a local-checkout skip, but the Docker harness still lacked CI source dependency provisioning. Verified all 356 Docker tests with the CI-minimal package render; two exact full-package retries were blocked before tests by transient ghcr.io Homebrew download failures.
