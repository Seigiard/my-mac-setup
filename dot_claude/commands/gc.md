---
allowed-tools: Bash(git add:*), Bash(git status:*), Bash(git commit:*)
description: Create a git commit
---

## Context

- Current git status: !`git status`
- Current git diff (staged and unstaged changes): !`git diff HEAD`
- Current branch: !`git branch --show-current`
- Recent commits: !`git log --oneline -10`

## Your task

Based on the above changes, analyze the diff and create git commits following these rules:

### Commit Strategy

1. **Analyze changes for logical grouping**: Review all modifications and identify logically related changes that should be committed together
2. **Split into multiple commits when needed**: If changes affect multiple unrelated features or fix multiple separate issues, create separate commits for each logical group
3. **Keep related changes together**: Changes that depend on each other or implement a single feature should be in one commit

### Examples of when to split commits:

- ✅ **Split**: Bug fix in component A + new feature in component B → 2 commits
- ✅ **Split**: Refactoring in module X + adding new API endpoint → 2 commits
- ✅ **Split**: Fixing typo in docs + implementing business logic → 2 commits
- ❌ **Don't split**: Adding new form field + updating its validation + adding UI component → 1 commit (related feature)
- ❌ **Don't split**: Fixing bug + adding test for that bug → 1 commit (related fix)

### Process:

1. Identify logical groups in the changes
2. If only one logical group exists, create a single commit
3. If multiple logical groups exist, create separate commits using `git add -p` or specific file paths
4. Write clear, descriptive commit messages for each commit

**IMPORTANT**: Do not append any co-authors to commit message like as `🤖 Generated with [Claude Code](https://claude.ai/code)`
