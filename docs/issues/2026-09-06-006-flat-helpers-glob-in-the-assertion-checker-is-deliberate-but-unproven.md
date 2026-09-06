---
title: "Flat helpers glob in the assertion checker is deliberate but unproven"
short_description: "Resolved: the helpers scan is now glob('helpers/**/*.bash') and a nested fixture pins the recursive scope; the record's proposed rglob remedy was disproved (rglob('helpers/*.bash') still matches only direct children) and its open question is answered by history - the flatness was intentional to avoid the vendored bats-libs tree, which no longer exists."
type: "follow-up"
category: "testing-ci"
tags: ["shell-lint","test-coverage","bashunit"]
date: "2026-09-06"
status: "done"
priority: "low"
closed: "2026-09-06"
---

## Why this exists

`scanned_files()` in `scripts/check_bats_assertions.py` reaches three file classes. Two use a
recursive `rglob`; the third uses a non-recursive `glob("helpers/*.bash")`, and the comment above it
states the flatness is deliberate:

```python
# tests/helpers/*.bash is sourced into that same test context (e.g. via
# `load 'helpers/common'`), so the identical quirk applies there. The flat
# glob is deliberate: it does not descend into subdirectories.
yield from sorted(tests_dir.glob("helpers/*.bash"))
```

Nothing proves that claim. `tests/test_bats_assertion_contract.py` has one fixture per scanned class,
so it would catch the glob breaking outright, but every helper fixture sits at the flat level and
none sits in a subdirectory. Changing `glob` to `rglob` keeps all four contract tests green.

The gap predates the `.bats` removal in commit `0e46c27` and was not caused by it. The
`helpers/bats-libs/vendor.bats` fixture that commit deleted looked like it covered this, but it did
not: it exercised the `.bats` loop's explicit `bats-libs` exclusion branch, a different mechanism
that no longer exists.

Impact today is zero and this is not a live bug. `tests/helpers/` contains no subdirectories at all,
so flat and recursive scanning select exactly the same files. The risk is latent: someone adds
`tests/helpers/<subdir>/foo.bash`, it silently escapes the bare-conditional guard, and a mid-test
`[[ ]]` in it is inert with nothing reporting it.

## Scope

Decide whether the flat glob is a contract, then make the code and its coverage agree.

If it is a contract, pin it. The existing `run_checker` harness builds a synthetic temp tree, so a
subdirectory helper fixture carrying a violation is expressible today even though the real
`tests/helpers/` has no subdirectories. Such a fixture must satisfy the repository's test-oracle
gate before it is written.

If it is not a contract, switch to `rglob` to match the other two classes, delete the "deliberate"
comment, and confirm the repository still lints clean.

Out of scope: restoring `.bats` scanning, and the `bats-libs` exclusion branch removed with it.

## Open decisions

- Is the non-recursive scope an intentional boundary, or an accident that the comment later
  rationalized? The commit that introduced it is the place to look; nothing in the current tree
  distinguishes the two readings.
- If it is intentional, what is the reason? The original exclusion target, vendored
  `tests/helpers/bats-libs/`, no longer exists, so the stated motive for skipping subdirectories may
  have left with it.

## Resolution

Fixed with glob('helpers/**/*.bash') in scripts/check_bats_assertions.py, and the stale 'the flat glob is deliberate' comment replaced with the reason the scan now recurses. Two of the record's statements did not survive checking and the fix departs from it on both. Its open question - intentional boundary or accident - is answered by history rather than by inspection: commit 0079760 introduced the flat glob with a concrete motive, avoiding the vendored tests/helpers/bats-libs tree, and commit 8d9ac4f later rewrote that motive into a bare assertion after 051d3de and 0e46c27 had removed the tree and the exclusion branch it served. Its proposed remedy, switching to rglob, is a no-op: rglob('helpers/*.bash') expands to glob('**/helpers/*.bash'), which finds a helpers directory at any depth but still only its direct .bash children. Coverage: tests/test_bats_assertion_contract.py's scan-reachability test gains a nested violation and its matching clean control. Oracle - consumer make lint, observable failure a helper in a subdirectory escaping the bare-conditional guard, oracle the checker's own exit status and reported path against a planted violation in a temp tree, never the glob's source text. Non-vacuity proved twice by independent mutation: reverting only the glob line to the flat form turns exactly the new assertion red while the other three tests stay green, and applying the record's rglob remedy leaves it red too, so the fixture would catch anyone following the record literally. Verified: make lint clean, 58 python tests OK.
