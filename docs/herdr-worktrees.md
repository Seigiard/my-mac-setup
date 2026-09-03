# Native Herdr worktrees

Herdr is the single owner of interactive Git worktree creation, opening,
closing, and removal. Linked checkouts are native child workspaces;
`herdr-worktree-identity` owns task-derived Git metadata, the one-time rename
of a newly generated branch, and its workspace title. The alias system remains
the sole owner of pane, tab, and agent identity.

- `Cmd+Shift+N` sends the existing `prefix+shift+g` transport sequence from
  Ghostty or kitty and opens Herdr's native new-worktree dialog.
- The workspace context menu provides `New worktree`, `Open worktree...`, and,
  on linked child workspaces, `Delete worktree checkout...`.
- Native removal asks Git to remove safely, offers a forced retry for dirty
  checkouts, closes the child workspace, and retains the branch.
- New checkouts live under `~/.worktrees/<repo>/<branch-slug>` through
  `[worktrees].directory` in `~/.config/herdr/config.toml`.

The repository-owned `seigi.worktree-setup` plugin handles the one capability
outside Herdr's native lifecycle: preparing a newly created checkout. Its sole
policy file is
`~/.config/herdr/plugins/config/seigi.worktree-setup/config.toml`. Tables are
keyed by the canonical `origin` remote, matching the former Worktrunk project
keys. A repository with no table receives no setup or fresh-base mutation.

On every `worktree.created` event, the plugin also records
`herdr-generated-worktree` in that checkout's Git administrative directory.
`herdr-worktree-identity` requires this lifecycle-owned marker before renaming a
`worktree/*` branch, so a manually created branch cannot be renamed from its
prefix alone. Git removes the marker with the linked worktree metadata.

## Repository policies

`membranehq/platform` retains the setup behavior of its `make worktree` target:

1. Refresh an untouched new branch from the remote default branch.
2. Copy `.env`, `console/.env`, `engine/api/.env`, `agent/benchmark/.env`, and
   `e2e-tests/.env` from the primary checkout when each file exists.
3. Run `make setup` through mise in the new checkout so repository-pinned tools
   win over global Homebrew versions.

The hook deliberately does not run `make init`, start databases, or copy
`node_modules`. Platform worktrees share the primary checkout's Postgres and
Redis, while `mise exec -- make setup` performs the supported dependency install
and build with the repository-pinned toolchain.

`Seigiard/my-mac-setup` enables only fresh-base behavior. It needs no setup
steps because the repository has no per-checkout dependencies or required
ignored environment files.

Fresh-base runs before copies and setup. It leaves the checkout unchanged when
the branch tracks an upstream, a same-name remote branch exists, its HEAD is not
contained by another local branch, the remote cannot be fetched, or files
appear before reset. Only an untouched new branch is reset to fetched
`origin/HEAD`.

## Ownership and deployment

- Chezmoi deploys and links `seigi.worktree-setup` from the repository-owned
  plugin directory.
- The GitHub-plugin installer removes a previously installed Worktrunk plugin.
- A one-time migration removes only the obsolete files this repository managed;
  unrelated files in the old config directory are preserved.
- Chezmoi changes are not live from this checkout. They become active only
  after this repository is committed, synced into chezmoi's source clone, and
  applied by the user.
