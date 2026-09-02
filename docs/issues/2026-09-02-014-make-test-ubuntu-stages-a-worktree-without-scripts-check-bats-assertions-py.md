---
title: "make test-ubuntu stages a worktree without scripts/check_bats_assertions.py"
short_description: "The test-full and test-ubuntu compose services mount only ../scripts/issues, so the staged /home/testuser/worktree lacks scripts/check_bats_assertions.py and the Makefile lint target it drives; scripts_test.sh:99 therefore fails in Docker and make test-ubuntu always exits non-zero, while CI stays green because it runs the suite against the real checkout."
type: "bug"
category: "testing-ci"
tags: ["docker","lint","test-harness"]
date: "2026-09-02"
status: "open"
priority: "high"
---

## Why this exists

`make test-ubuntu` and `make test-docker` stage a writable copy of the repository inside the container before running `tests/run-post-apply.sh full`. The staging step in `docker/docker-compose.yml` copies `home/`, `tests/`, `docs/issues/`, `Makefile`, `README.md`, and exactly one file out of `scripts/`:

```
- ../scripts/issues:/home/testuser/issues-cli:ro
...
cp /home/testuser/issues-cli /home/testuser/worktree/scripts/issues
```

`Makefile:75` (`lint`) ends with `python3 scripts/check_bats_assertions.py tests`, and that file is never staged. Inside the container the target dies with:

```
python3: can't open file '/home/testuser/worktree/scripts/check_bats_assertions.py': [Errno 2] No such file or directory
make: *** [Makefile:75: lint] Error 2
```

`tests/bashunit/scripts_test.sh:99` (`lint target propagates shellcheck failures`) runs `make -C "$repo_root" lint` twice with a stubbed `shellcheck`. Its second leg asserts success, which the missing file makes impossible, so the case fails and `make test-ubuntu` exits non-zero on every run regardless of the change under test.

Impact: the target that repository policy names as the proof for a change to a managed file cannot report a clean verdict. Every user of it has to read the failure list and decide by hand whether the one red case is theirs. Observed on 2026-09-02 while verifying the zsh-reserved-name guard: 282 passed, 1 failed, and the single failure was this one.

CI is unaffected. `.github/workflows/test-dotfiles.yml` runs `tests/run-post-apply.sh full` and `make lint` against the real checkout, where `scripts/check_bats_assertions.py` exists, so the workflow stays green and the defect is visible only in the local Docker path.

## Scope

Stage the whole `scripts/` directory into the container worktree instead of the single `scripts/issues` file, in both the `test-full` and `test-ubuntu` services, and keep the existing `scripts/issues` destination path intact so `make test-issues` coverage does not move. Then confirm `tests/bashunit/scripts_test.sh:99` passes under `make test-ubuntu`.

## Open decisions

Whether the container should stage the repository by an allowlist at all. Every new repo-root file that `make lint` or a test target reads has to be added in two places, and this is the second such omission. Copying the tracked file set once would remove the class, at the cost of a larger container payload.
