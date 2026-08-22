---
name: se-cleanup
description: Run post-merge cleanup from a linked worktree or the primary checkout, then return to updated main.
---

# Post-merge cleanup

Clean up only the feature branch for the current completed pull request. Use Git worktree metadata and GitHub pull-request data as authority. Do not infer a checkout role from its directory name.

## 1. Resolve the cleanup context

Capture the feature branch before you switch checkouts:

```sh
current_checkout="$(git rev-parse --show-toplevel)"
feature_branch="$(git branch --show-current)"
git worktree list --porcelain
```

Stop if the branch is empty, is `main`, or does not match the `branch refs/heads/<feature_branch>` value in the current worktree record.

Read `git worktree list --porcelain` as records. The first `worktree` record is the primary checkout. Set `primary_checkout` to that record's path. Compare the current checkout with that path.

### Linked worktree

If the current checkout differs from the primary checkout, set `linked_worktree` to the current worktree path. Confirm its metadata names the captured feature branch. Run all remaining Git commands from the primary checkout.

### Primary checkout feature branch

If the current checkout equals the primary checkout, confirm that it is on the captured feature branch. Leave `linked_worktree` unset. Use this checkout for all remaining commands.

If the metadata is incomplete, inconsistent, or identifies more than one current worktree, preserve the worktree and branches. Report the ambiguity and stop.

## 2. Update the primary checkout

Switch without forcing. Pull only a fast-forward update from the configured upstream of `main`:

```sh
git -C "$primary_checkout" switch main
git -C "$primary_checkout" pull --ff-only
```

If either command fails, do not remove the worktree or branches. Report the failure and stop.

## 3. Verify the merged pull request

Resolve the GitHub repository from the primary checkout. Query all pull requests whose head branch is the captured feature branch:

```sh
repo="$(cd "$primary_checkout" && gh repo view --json nameWithOwner --jq .nameWithOwner)"
gh pr list --repo "$repo" --state all --head "$feature_branch" \
  --json number,state,mergedAt,headRefName,headRepository,url
```

Continue only if the result contains exactly one pull request and all these facts agree:

- `state` is `MERGED` and `mergedAt` is present.
- `headRefName` exactly equals the captured feature branch.
- `headRepository.nameWithOwner` exactly equals the repository resolved from `origin`.

If a GitHub command fails, treat its result as missing. If the state is not `MERGED`, the result is missing or ambiguous, or either head identity differs, do not clean up. Preserve the local and remote feature branches and stop. Report the observed pull-request result and the failed check.

## 4. Remove completed work

Run this section only after every merged pull-request check succeeds.

If `linked_worktree` is set, remove it without forcing:

```sh
git -C "$primary_checkout" worktree remove "$linked_worktree"
```

If removal fails, preserve both feature branches and stop. Do not discard dirty work.

Delete the local branch without forcing. Delete the remote branch only after local deletion succeeds:

```sh
git -C "$primary_checkout" branch -d "$feature_branch"
git -C "$primary_checkout" push origin --delete "$feature_branch"
```

If a command fails, stop. Report the completed operations and the item that remains. Do not retry with a force option.

## 5. Report the observed result

Inspect the final state instead of inferring success from earlier commands:

```sh
git -C "$primary_checkout" status --short --branch
git -C "$primary_checkout" worktree list --porcelain
git -C "$primary_checkout" branch --list "$feature_branch"
git -C "$primary_checkout" ls-remote --heads origin "$feature_branch"
```

Report:

- the primary checkout path, current branch, upstream, and update result;
- the merged pull-request URL and verified head identity;
- whether a linked worktree was removed or was not present;
- whether the local and remote feature branches were deleted;
- any preserved item and the command or safety check that stopped cleanup.
