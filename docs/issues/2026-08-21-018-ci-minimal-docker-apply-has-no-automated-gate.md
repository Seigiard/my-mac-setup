---
title: "The CI-minimal Docker apply has no automated gate, so a base-image downgrade would break it silently"
short_description: "Only a manual `MMS_CI_MINIMAL=1 docker compose -f docker/docker-compose.yml run --rm test-full` verifies that Ubuntu supplies Git 2.35 or newer for `merge.conflictStyle = zdiff3` and still includes Python 3."
type: "follow-up"
category: "testing-ci"
tags: ["testing-ci","follow-up"]
date: "2026-08-21"
status: "done"
priority: "medium"
parent-plan: "docs/plans/2026-08-21-0337-fix-python3-declared-dependency-plan.md"
closed: "2026-08-23"
---

## Why this exists

`brew "git"` left the CI-minimal Brewfile render because the Docker test image moved to
`ubuntu:24.04`, whose apt git is 2.43.0 and therefore accepts the
`merge.conflictStyle = zdiff3` that `home/dot_gitconfig.tmpl:27` deploys. Ubuntu 22.04's
apt git 2.34.1 rejects it and aborts the apply's Oh My Zsh clone before any test runs.

That dependency is real but nothing enforces it. It is held up by two comments —
`docker/Dockerfile.ubuntu:1-8` and the rationale block above `assert_minimal_brewfile()` in
`tests/templates.bats` — and by one command a person has to remember to type:

```
MMS_CI_MINIMAL=1 docker compose -f docker/docker-compose.yml run --rm test-full
```

No job in `.github/workflows/test-dotfiles.yml` runs it. `make test-ubuntu` cannot
substitute: it runs the `test-quick` service, which sets no `MMS_CI_MINIMAL`
(`docker/docker-compose.yml:67` deliberately omits the entry — see
`docs/issues/2026-08-20-014`), so its apply installs the full Brewfile including
Homebrew's git and stays green.

So a future change to `FROM ubuntu:24.04` breaks the minimal apply while every automated
check keeps passing. When it does surface, the error names `zdiff3`, not `git`, and it
happens mid-apply — nothing points at the base image that caused it.

The template tests do not close this. `tests/templates.bats` inspects rendered lines; it
cannot observe which git the image actually has.

A second, narrower version of the same gap: nothing asserts the Docker image's apt layer
still contains `python3`. `docker/Dockerfile.ubuntu` installing it is the load-bearing half
of the `python3` work, and the only thing that would catch its removal is a post-apply
assertion failing minutes later inside a built image, not the fast pre-apply gate.

Raised by the independent cross-model adversarial pass and by the correctness reviewer
during the code review of the plan named in `parent-plan`.

## Scope

1. Add a build-time assertion to `docker/Dockerfile.ubuntu` that the installed git is at
   least 2.35, so a base-image downgrade fails at `make build-docker` naming the version,
   rather than mid-apply naming `zdiff3`. Consider the same for `python3` presence.
2. Decide whether the CI-minimal apply becomes an automated gate. The candidates:
   - a scheduled or `workflow_dispatch` job that runs the `MMS_CI_MINIMAL=1 test-full`
     command above, accepting that it needs Docker on the runner;
   - or leaving it manual and accepting the comments as the only guard.
   Note that `docs/issues/2026-08-21-003` established that the Actions-billing premise
   behind some of this work was void, so cost is a live input to this decision rather than
   an assumed blocker.
3. Whatever is chosen, the skip-set parity check between the minimal and full renders is
   currently done by hand and compared by eye. It matched at 13 skips each on
   2026-08-21. Any future comparison must be taken against a post-change baseline, because
   removing the `python3` skip guards removed up to 56 potential skips.

## Resolved decisions

- Do not add a scheduled or `workflow_dispatch` Docker job here. The guarded failure is a
  developer-local Docker image downgrade, while push and pull_request runs use GitHub
  runner git and already select the CI-minimal render directly.
- Put the executable git and python3 assertions in `docker/Dockerfile.ubuntu`, then pin
  those assertions with a focused Bats source test. The Dockerfile catches the failure
  during `make build-docker`; the Bats test prevents the gate from disappearing silently.

## Resolution

Added a Dockerfile build-time gate that asserts apt git is at least 2.35 and python3
is present before any CI-minimal apply can run. Added a focused Bats regression test
that fails if the Dockerfile loses the executable git-version comparison or python3
assertion. Chose not to add a scheduled or manual Docker CI job because this issue
protects the local Docker image path, while GitHub push and pull_request runs use runner
git directly. Verified with the focused Bats test, make test-issues, make lint, and
make build-docker.
