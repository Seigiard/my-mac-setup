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
  --json number,state,mergedAt,headRefName,headRefOid,headRepository,url
```

Continue only if the result contains exactly one pull request and all these facts agree:

- `state` is `MERGED` and `mergedAt` is present.
- `headRefName` exactly equals the captured feature branch.
- `headRefOid` exactly equals the local feature branch tip.
- `headRepository.nameWithOwner` exactly equals the repository resolved from `origin`.

If a GitHub command fails, treat its result as missing. If the state is not `MERGED`, the result is missing or ambiguous, or either head identity differs, do not clean up. Preserve the local and remote feature branches and stop. Report the observed pull-request result and the failed check.

## 4. Remove completed work

Run this section only after every merged pull-request check succeeds.

If `linked_worktree` is set, first prove that its superproject and every initialized submodule are clean:

```sh
git -C "$linked_worktree" status --porcelain
git -C "$linked_worktree" submodule foreach --quiet --recursive \
  'test -z "$(git status --porcelain)"'
```

If either check reports work or fails, preserve the worktree and both branches. Report the dirty path and stop.

Try ordinary removal first:

```sh
git -C "$primary_checkout" worktree remove "$linked_worktree"
```

A clean worktree with initialized submodules can still fail with `working trees containing submodules cannot be moved or removed`. Only for that exact error, deinitialize its clean submodules and retry with `--force`:

```sh
git -C "$linked_worktree" submodule deinit --all
git -C "$primary_checkout" worktree remove --force "$linked_worktree"
```

Here `--force` bypasses Git's structural submodule restriction. The preceding clean checks prevent it from discarding work. For any other removal failure, preserve both branches and stop.

Delete the local branch without forcing first:

```sh
git -C "$primary_checkout" branch -d "$feature_branch"
```

A squash-merged pull request does not make the feature tip an ancestor of `main`, so `-d` can reject a safely merged branch. Only if the merged pull-request gate succeeded and its `headRefOid` still exactly equals the local branch tip, retry with `git -C "$primary_checkout" branch -D "$feature_branch"`.

Delete the remote branch only after local deletion succeeds:

```sh
git -C "$primary_checkout" push origin --delete "$feature_branch"
```

If a command fails outside the two bounded force cases above, stop. Report the completed operations and the item that remains.

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
