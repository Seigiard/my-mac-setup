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
- New checkouts live under `~/.herdr/worktrees/<repo>/<branch-slug>`;
  `~/.config/herdr/config.toml` has no `[worktrees]` section.

The standalone [`seigi.worktree-setup`](https://github.com/Seigiard/herdr-worktree-setup)
plugin handles the one capability outside Herdr's native lifecycle: preparing a
newly created checkout. Its sole policy file is
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
2. Copy `CLAUDE.local.md`, `AGENTS.local.md`, `.revmux/profile.md`, `.env`,
   `console/.env`, `engine/api/.env`, `agent/benchmark/.env`, and
   `e2e-tests/.env` from the primary checkout when each file exists.
3. Run `make setup` through mise in the new checkout so repository-pinned tools
   win over global Homebrew versions.

The hook deliberately does not run `make init`, start databases, or copy
`node_modules`. Platform worktrees share the primary checkout's Postgres and
Redis, while `mise exec -- make setup` performs the supported dependency install
and build with the repository-pinned toolchain.

## Setup-status gate

When a configured setup is active, `seigi.worktree-setup` writes
`herdr-worktree-setup` in the checkout's Git administrative directory. The
marker is one line:

```text
running <pid> <start-unix-ms>
done <exit-code> <end-unix-ms>
```

The Claude Code, OpenCode, and Pi adapters read this marker for each tool call.
They block build, test, install, and dev commands while a live setup is under
five minutes old. After five minutes, the command runs; on Claude Code it also
carries a context note that setup looks stuck. A successful `done 0` marker
allows commands.

A failed setup blocks the first gated command and tells the agent to retry with
`mise exec -- make setup`. The adapter records that denial for the exact marker
line, so the same failure is not repeated. A new marker line is denied again.
A `running` marker whose PID is no longer alive is treated as an interrupted
failure. Missing, malformed, unreadable, or non-Git marker state fails open.

`Seigiard/my-mac-setup` refreshes the base and runs `npm ci` to install the
checkout's YAML and frontmatter check tools. Git hooks are shared between linked
worktrees, but their commands resolve dependencies from the current checkout.
Worktrees created outside Herdr need `npm ci` before committing or pushing.

Fresh-base runs before copies and setup. It leaves the checkout unchanged when
the branch tracks an upstream, a same-name remote branch exists, its HEAD is not
contained by another local branch, the remote cannot be fetched, or files
appear before reset. Only an untouched new branch is reset to fetched
`origin/HEAD`.

## Claude Code nested worktrees

Claude Code's `EnterWorktree` and worktree-isolated child agents use the global
`WorktreeCreate` hook. The hook creates
`<checkout>/.claude/worktrees/<name>` on `worktree-<name>`. It uses
`origin/HEAD` when that ref resolves, and otherwise uses the current `HEAD`.
It does not fetch. An unoccupied local `worktree-<name>` branch is reused with
its tip unchanged. An already registered path is returned as is; a stale
registration whose directory is gone is removed first, and other worktree
registrations stay untouched.

After Git creates the checkout, the hook invokes the `seigi.worktree-setup`
plugin with the checkout path and an empty branch field. The hook finds the
plugin through `herdr plugin list --json` (the `plugin_root` of the enabled
`seigi.worktree-setup` entry); `CLAUDE_WORKTREE_SETUP_PLUGIN_DIR` overrides it.
The empty field tells the plugin to skip fresh-base and the
`herdr-generated-worktree` marker, so the new branch keeps the parent checkout's
unpushed commits and `herdr-worktree-identity` leaves it alone. Setup is best
effort: the hook still returns the created path when a setup prerequisite is
missing (`herdr`, `jq`, `bun`, an enabled plugin, its `setup.ts`) or when setup
fails, and prints the reason on stderr. Untracked files reach the checkout only
through the plugin's `copy` list in `config.toml`: the hook replaces Claude
Code's default creation, including its `.worktreeinclude` handling.

Claude Code's matching `WorktreeRemove` hook refuses a path that contains
another registered worktree. Otherwise it force-removes the linked checkout. It
deletes a `worktree-*` branch when another local branch or remote-tracking ref
contains its tip; otherwise it keeps the branch and says so on stderr. A missing
path counts as removed; a plain directory is rejected and left untouched.

Claude Code keeps subagent worktrees and never passes them to `WorktreeRemove`.
Remove a leftover with `git worktree remove --force
<checkout>/.claude/worktrees/<name>` from the primary checkout, then delete its
`worktree-<name>` branch if its work is merged.

Setup runs synchronously and can block the child agent for 30–100 seconds. This
cost is accepted because the child already pays the setup cost later when setup
is run by hand. Codex and OpenCode create their subagent worktrees without these
hooks, so those checkouts get no setup.

## Provenance boundary

Worktree creation is native Herdr behavior. The setup plugin observes the
`worktree.created` event after creation and does not create or claim tabs, panes,
workspaces, or worktrees. The managed `herdr` PATH wrapper owns provenance only
for the creation commands it intercepts; plugin-triggered or otherwise
unsupported creation paths remain unknown-provenance paths.

## Ownership and deployment

- Chezmoi installs and enables the reviewed `seigi.worktree-setup` package from
  GitHub, while retaining the repository-keyed policy file here.
- The one-time migration removes the formerly managed local implementation only
  after the standalone package is installed and enabled. Failed installation or
  enablement retains the local plugin for the next apply.
- The GitHub-plugin installer removes a previously installed Worktrunk plugin.
- A one-time migration removes only the obsolete local manifest and handler
  after cutover; unrelated files left in that directory are preserved, as is
  the separately managed policy directory.
- To remove the standalone package from this machine, first remove its entry
  from the `plugins` list in
  `home/.chezmoiscripts/run_onchange_after_7-install-herdr-github-plugins.sh.tmpl`,
  apply the dotfiles, then run `herdr plugin uninstall seigi.worktree-setup`.
  Uninstalling it without removing that managed entry is not durable: the next
  apply restores the package by design.
- Chezmoi changes are not live from this checkout. They become active only
  after this repository is committed, synced into chezmoi's source clone, and
  applied by the user.
