# Worktrunk-managed Herdr workspaces

Worktrunk is the single owner of interactive Git worktree creation, setup,
merge, and removal in Herdr. The `herdr-worktrunk` plugin presents Worktrunk
checkouts as native Herdr workspaces; `herdr-task-sync` remains the separate
owner of pane labels and Git metadata.

Use the managed Herdr bindings instead of Herdr's built-in worktree dialog:

- `prefix+shift+g` switches to an existing worktree or creates one from the
  default branch.
- `prefix+shift+d` removes a worktree through Worktrunk's safety checks.
- `prefix+shift+m` merges a worktree through Worktrunk and then removes it.

The source of truth for personal Worktrunk policy is
`home/private_dot_config/worktrunk/config.toml`, deployed to
`~/.config/worktrunk/config.toml`. Do not add an independent Herdr
`worktree.created` plugin for moving or seeding checkouts: independent event
handlers have no shared transaction or ordering and can race over the path.

## Repository policies

`membranehq/platform` retains the behavior of its `make worktree` target:

1. Create a sibling checkout at `../platform-<branch>` from the default branch.
2. Copy `.env`, `console/.env`, `engine/api/.env`, `agent/benchmark/.env`, and
   `e2e-tests/.env` from the primary checkout when each file exists.
3. Run `make setup` in the new checkout.

The hook deliberately does not run `make init`, start databases, or copy
`node_modules`. Platform worktrees share the primary checkout's Postgres and
Redis, while `make setup` performs the supported dependency install and build.

`Seigiard/my-mac-setup` creates checkouts at
`.worktrees/<branch>`. It needs no setup hook because the repository has no
per-checkout dependencies or required ignored environment files.

## Ownership and deployment

- Homebrew installs `wt` from the `worktrunk` formula.
- The managed Herdr GitHub-plugin installer installs and enables
  `devashish2203/herdr-worktrunk`.
- `herdr-auto-update` trusts that GitHub owner for forward-only plugin updates.
- Chezmoi changes are not live from this checkout. They become active only
  after this repository is committed, synced into chezmoi's source clone, and
  applied by the user.
