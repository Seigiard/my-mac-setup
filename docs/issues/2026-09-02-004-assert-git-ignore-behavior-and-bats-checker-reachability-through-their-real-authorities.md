---
title: "Assert Git ignore behavior and Bats checker reachability through their real authorities"
short_description: "tests/test_issues.py inspects .gitignore text instead of Git's effective decision, and tests/test_bats_assertion_contract.py accepts the checker's own file inventory without a reachability fixture per supported test-shell surface."
type: "follow-up"
category: "testing-ci"
tags: ["semantic-testing","source-ownership"]
date: "2026-09-02"
status: "open"
priority: "medium"
---

## Why this exists

Split from 2026-09-01-002. tests/test_issues.py:517-521 reads .gitignore line by line, so a rule that is present but overridden, or a path that is ignored through another mechanism, produces the same verdict as correct behavior. tests/test_bats_assertion_contract.py:128-136 trusts the checker's own list of files it claims to scan, so a shell-file class the checker silently stops reaching keeps passing.

## Scope

Replace the .gitignore text assertions with git check-ignore results and tracked-path evidence for the same paths, keeping one ignored and one tracked control. Add a reachability fixture for every shell-file class the Bats assertion checker claims to protect: plant a known violation in each class and require the checker to report it, with a clean control per class. Strengthen the existing tests instead of adding new suites. Verify with the two python suites, then make test-issues.

## Open decisions

Which sourced shell-helper classes the Bats assertion checker must cover; the implementation should enumerate the classes it currently reaches and state any it deliberately excludes.
