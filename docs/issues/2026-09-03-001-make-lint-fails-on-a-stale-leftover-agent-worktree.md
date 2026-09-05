---
title: "make lint fails on a stale leftover agent worktree"
short_description: "The shellcheck find at Makefile:62 excludes ./.git, ./.worktrees, */node_modules and ./.context but not ./.claude/worktrees, so make lint walks any leftover agent worktree and that worktree's findings fail lint on an otherwise clean tree; the fix is an added -not -path \"./.claude/worktrees/*\", since the untracked .git/info/exclude entry find never consults cannot do it."
type: "chore"
category: "repository-maintenance"
tags: ["lint","worktree"]
date: "2026-09-03"
status: "open"
priority: "medium"
---

## Why this exists

The shellcheck sweep in `make lint` (`Makefile:62`) enumerates its inputs with
`find`:

```
find . -name "*.sh" -type f -not -path "./.git/*" -not -path "./.worktrees/*" -not -path "*/node_modules/*" -not -path "./.context/*" -not -path "./tests/bashunit/*_test.sh" | xargs shellcheck --severity=warning
```

`./.claude/worktrees/` is not excluded. Agent worktrees live there, so every
`.sh` file inside one is linted as if it were repository source. In the main
checkout that is currently 20 of the 60 `.sh` files the command enumerates.
Whether `make lint` passes then depends on the contents of whichever worktree
happens to be left over, not on the tree being linted.

Measured 2026-09-05 in `/Users/seigiard/Projects/my-mac-setup`: the leftover
worktree is `.claude/worktrees/fix-inner-bats-wallclock-flake` and the pipeline
above exits 0 with empty output, so the failure is not currently reproducing.
The worktree named when this issue was filed (`agent-af16a2e90bb22742f`) no
longer exists. The exposure is structural and unchanged; only the symptom is
dormant.

`.gitignore` cannot fix this. The exclusion currently lives untracked in
`.git/info/exclude:26` as `**/.claude/worktrees/`, and `find` consults neither
file.

## Scope

Add `-not -path "./.claude/worktrees/*"` to the `find` at `Makefile:62`, so
lint's input set depends only on repository source.

## Open decisions

- Whether the other three `find` invocations in the target (`Makefile:63-64`,
  rooted at `home`) need the same treatment. They are rooted outside
  `.claude/`, so they appear unaffected; confirm before deciding.
