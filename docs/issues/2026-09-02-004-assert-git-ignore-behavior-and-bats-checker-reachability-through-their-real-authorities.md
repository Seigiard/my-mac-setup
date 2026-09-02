---
title: "Assert Git ignore behavior and Bats checker reachability through their real authorities"
short_description: "tests/test_issues.py inspects .gitignore text instead of Git's effective decision, and tests/test_bats_assertion_contract.py accepts the checker's own file inventory without a reachability fixture per supported test-shell surface."
type: "follow-up"
category: "testing-ci"
tags: ["semantic-testing","source-ownership"]
date: "2026-09-02"
status: "done"
priority: "medium"
closed: "2026-09-02"
---

## Why this exists

Split from 2026-09-01-002. tests/test_issues.py:517-521 reads .gitignore line by line, so a rule that is present but overridden, or a path that is ignored through another mechanism, produces the same verdict as correct behavior. tests/test_bats_assertion_contract.py:128-136 trusts the checker's own list of files it claims to scan, so a shell-file class the checker silently stops reaching keeps passing.

## Scope

Replace the .gitignore text assertions with git check-ignore results and tracked-path evidence for the same paths, keeping one ignored and one tracked control. Add a reachability fixture for every shell-file class the Bats assertion checker claims to protect: plant a known violation in each class and require the checker to report it, with a clean control per class. Strengthen the existing tests instead of adding new suites. Verify with the two python suites, then make test-issues.

## Open decisions

Which sourced shell-helper classes the Bats assertion checker must cover; the implementation should enumerate the classes it currently reaches and state any it deliberately excludes.

**Decision (2026-09-02):** `tests/helpers/*.bash` must be scanned, in addition to the two classes the checker already reached (`*.bats`, excluding the vendored `helpers/bats-libs` tree, and `bashunit/*_test.sh`). Rationale: these helpers are `source`d/`load`ed into the same bashunit test context as the suite files (e.g. `smoke_test.sh` does `load 'helpers/common'`), so the bash 3.2 ERR-trap quirk the checker exists for — a bare mid-test `[[ ]]` or `(( ))` silently failing to fail the test — applies to them identically. The glob is flat (`helpers/*.bash`, not recursive), which naturally excludes anything under a nested `helpers/bats-libs/` vendor directory without needing a separate exclusion rule.

`palette_boot.py` under `tests/helpers/` is out of scope: it is Python, not shell, so the bash-specific ERR-trap quirk does not apply to it.

Widening the scan surfaced three real violations, all the same shape — a bare `[[ ]]` as the final statement of a boolean-predicate helper function, whose exit status is the function's return value and is consumed explicitly by every call site (`if is_macos; then`, `is_macos || skip ...`, `_hts_engine_pid_live ... || continue`): `tests/helpers/common.bash` (`is_macos`, `is_linux`) and `tests/helpers/herdr_task_sync.bash` (`_hts_engine_pid_live`). Fixed by appending `|| return 1` to each, matching the `[[ cond ]] || return N` idiom already used throughout these same files (e.g. `herdr_task_sync.bash:76`) and the vendored `tests/lib/bashunit`. No false positives were found in the widened scope.

**Addendum (2026-09-02, from cross-model review):** `tests/bashunit/test-dsl.bash` must also be scanned. It is the shared bashunit ERR-trap DSL every `tests/bashunit/*_test.sh` suite sources, and its own header names this checker's exact target hazard as applying to itself (`docs/issues/2026-08-27-002-bare-mid-test-assertions-are-silently-inert-in-bats.md`). It matched neither existing `bashunit/` glob (no `_test.sh` suffix) nor the new `helpers/*.bash` glob (wrong directory), so the original widening left the single most widely-sourced file in `tests/` unreached. Added `tests_dir.rglob("bashunit/*.bash")` to `scanned_files()` and a matching reachability fixture. No violations exist in the file today.

## Resolution

Merged in PR #134. Ignore behavior is asserted through git check-ignore and git ls-files with controls in both directions plus a nonexistent-child probe, so a future directory-only rule cannot hide files while leaving the directory visible. The Bats assertion checker gained per-class reachability fixtures, and its scan was widened to tests/helpers/*.bash and tests/bashunit/*.bash, including test-dsl.bash, whose own header names the hazard the checker exists for. Three predicate helpers got an explicit '|| return 1' rather than teaching the checker an exemption that would blind it to a bare conditional at the end of a test body.
