# Worktrunk-managed Herdr workspaces

Worktrunk is the single owner of interactive Git worktree creation, setup,
merge, and removal in Herdr. The `herdr-worktrunk` plugin presents Worktrunk
checkouts as native Herdr workspaces; `herdr-task-sync` remains the separate
owner of pane labels and Git metadata.

Use the same direct terminal shortcuts and command palette as the rest of the
Herdr workspace workflow:

- `Cmd+Shift+N` immediately creates and opens a worktree from the default branch,
  named `worktree-YYYYMMDD-HHMMSS-ffffff`.
- `Cmd+Shift+P` opens the command palette. Search for `worktree` or use the
  `wt`, `wtn`, `wtd`, and `wtm` shortcuts to switch/create interactively, create
  immediately, remove, or merge a worktree. The interactive picker opens as a
  floating popup.
- Herdr's workspace action menus expose the same Worktrunk open, remove, and
  merge operations.

The underlying `prefix+shift+g` binding is a transport target for Ghostty and
kitty, which send the complete Herdr sequence for `Cmd+Shift+N`. It invokes the
local command-palette plugin's direct-create action and does not require typing
`Ctrl+B` manually.

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
3. Run `make setup` through mise in the new checkout so repository-pinned tools
   win over global Homebrew versions.

The hook deliberately does not run `make init`, start databases, or copy
`node_modules`. Platform worktrees share the primary checkout's Postgres and
Redis, while `mise exec -- make setup` performs the supported dependency install
and build with the repository-pinned toolchain.

`Seigiard/my-mac-setup` creates checkouts at
`.worktrees/<branch>`. It needs no setup hook because the repository has no
per-checkout dependencies or required ignored environment files.

## Ownership and deployment

- Homebrew installs `wt` from the `worktrunk` formula.
- The managed Herdr GitHub-plugin installer installs and enables
  `devashish2203/herdr-worktrunk`.
- The plugin-specific managed config presents its interactive picker as a popup.
- `herdr-auto-update` trusts that GitHub owner for forward-only plugin updates.
- Chezmoi changes are not live from this checkout. They become active only
  after this repository is committed, synced into chezmoi's source clone, and
  applied by the user.
