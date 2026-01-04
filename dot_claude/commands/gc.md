Looking at your request, you want the agent to check the last commit and potentially combine changes with it if it's still local (not pushed yet).

Here's the enhanced version:

---

allowed-tools: Bash(git add:_), Bash(git status:_), Bash(git commit:_), Bash(git log:_), Bash(git show:_), Bash(git reset:_), Bash(git commit --amend:\*)
description: Create a git commit with smart combining logic

---

## Context

- Current git status: !`git status`
- Current git diff (staged and unstaged changes): !`git diff HEAD`
- Current branch: !`git branch --show-current`
- Recent commits: !`git log --oneline -10`
- Last commit details: !`git show --stat HEAD`
- Check if last commit is pushed: !`git log @{u}..HEAD --oneline` (if empty, last commit is pushed)

## Your task

Based on the above changes, analyze the diff and create git commits following these rules:

### Pre-commit Analysis

1. **Check last commit status**: Determine if the last commit is local-only (not pushed to remote)
2. **Evaluate combination potential**: If last commit is local, assess whether current changes logically belong with the previous commit
3. **Decide on strategy**: Choose between new commit, amending last commit, or creating multiple commits

### Combination Criteria (for amending last commit)

**Combine with last commit when:**

- Last commit is local (not pushed)
- Current changes directly relate to the same feature/fix as last commit
- Changes are small refinements, bug fixes, or missing pieces of the previous commit
- Combined commit would still have a single, clear purpose

**Examples of good candidates for amending:**

- ✅ Last commit: "Add user validation", Current: "Fix typo in validation message"
- ✅ Last commit: "Implement login form", Current: "Add missing form styling"
- ✅ Last commit: "Add API endpoint", Current: "Fix endpoint response format"

**Don't combine when:**

- ❌ Changes implement different features entirely
- ❌ Last commit is already pushed to remote
- ❌ Current changes are substantial enough to warrant separate documentation

### Commit Strategy

1. **Analyze changes for logical grouping**: Review all modifications and identify logically related changes that should be committed together
2. **Split into multiple commits when needed**: If changes affect multiple unrelated features or fix multiple separate issues, create separate commits for each logical group
3. **Keep related changes together**: Changes that depend on each other or implement a single feature should be in one commit

### Process:

1. Check if last commit is pushed or local-only
2. If local, evaluate whether current changes should be combined with it
3. If combining: use `git commit --amend` to update the last commit
4. If not combining: identify logical groups in current changes
5. Create appropriate commits using `git add` with specific paths when needed
6. Write clear, descriptive commit messages for each commit

**IMPORTANT**: Do not append any co-authors to commit message like `🤖 Generated with [Claude Code](https://claude.ai/code)`
