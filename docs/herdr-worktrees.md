# Native Herdr worktrees

Herdr is the single owner of interactive Git worktree creation, opening,
closing, and removal. The `Cmd+Shift+N` keybinding invokes the `my-worktree`
app mod (`home/private_dot_config/herdr-app/mods/my-worktree`, #623). Linked
checkouts are native child spaces. The worktree-identity component renames an
authorized generated branch from an agent session's first prompt, then labels
the matching Herdr app space.

- `Cmd+Shift+N` creates and opens a checkout through the `my-worktree` mod,
  then runs `herdr-worktree-setup-run` for setup.
- The setup package runs from `~/.local/lib/herdr-worktree-setup`. Claude Code
  invokes the same package through its `WorktreeCreate` hook.
- The `my-spaces` sidebar opens `my-menu` for a space. Its `New worktree` item
  opens `my-worktree`; `Open worktree` remains an open action.
- The `my-tabs` `+` button opens `my-new-menu`, whose `New worktree…` item also
  opens `my-worktree`. `layouts/my-main.json` uses `my-tabs`.
- Native removal asks Git to remove safely, offers a forced retry for dirty
  checkouts, closes the child workspace, and retains the branch.
- New checkouts live under `~/.herdr/worktrees/<repo>/<branch-slug>`;
  worktree setup policy is managed separately and has no `[worktrees]` section.

The standalone [`seigi.worktree-setup`](https://github.com/Seigiard/herdr-worktree-setup)
package is pinned as a chezmoi external at
`~/.local/lib/herdr-worktree-setup`. It handles the one capability outside
Herdr's native lifecycle: preparing a newly created checkout. The Herdr app's
`my-worktree` mod (`Cmd+Shift+N`) and the Claude Code `WorktreeCreate` hook both
run it by fixed path. Its sole policy file is
`~/.config/herdr-worktree-setup/config.toml`. Tables are keyed by the canonical
`origin` remote, matching the former Worktrunk project keys. A repository with
no table receives no setup or fresh-base mutation.

## Selected repository policies

The 2026-11-15 review covers the 21 repositories remaining in the user's
selected scope. `dicex` was explicitly excluded from worktree setup at the
user's request.
The policy adds setup only where the repository has a documented,
non-interactive dependency step or needs an existing ignored local file.
Every install is scoped to the checkout and uses its lockfile where the
project provides one. No fresh-base policy was added.

| Canonical origin | Worktree setup |
| --- | --- |
| `github.com/Seigiard/agent-reports` | `npm ci --prefix worker`; `uv sync --locked --directory cli`. The worker owns `worker/package-lock.json`; the CLI owns `cli/uv.lock`. |
| `github.com/Seigiard/my-mac-setup` | Existing policy preserved: `fresh-base = true` and `npm ci`. No new setup behavior was added. |
| `github.com/Seigiard/Bento` | `bun install --frozen-lockfile` from the Bun CI workflow and `bun.lock`. |
| `github.com/Seigiard/dnd-generator` | Copy the existing ignored `.env.local`, then run `bun install --frozen-lockfile`. The copy preserves the local `NEXT_PUBLIC_CONVEX_URL`; its value is not read or recorded. |
| `github.com/Seigiard/epg-scrapper` | `npm ci`, documented in the README and CI, with `package-lock.json`. |
| `github.com/Seigiard/herdr-worktree-setup` | `npm ci`, required by the development README and CI, with `package-lock.json`. |
| `github.com/Seigiard/jk-nav` | `npm ci`, documented in the README and CI, with `package-lock.json`. |
| `github.com/Seigiard/opds-generator` | Initialize `ui/vendor/foliate-js` with Git, then run selected policy `bun install --frozen-lockfile` with `bun.lock`. CI runs plain `bun install` at `.github/workflows/docker.yml:34-35`; the frozen flag matches the production Dockerfile stage. |
| `github.com/Seigiard/opds-viewer` | `bun install --frozen-lockfile` from the repository instructions and CI, with `bun.lock`. |
| `github.com/Seigiard/opml-generator` | `bun install --frozen-lockfile` from CI, with `bun.lock`. |
| `github.com/Seigiard/owlbear-muster-roll` | `bun install --frozen-lockfile` from CI, with `bun.lock`. |
| `github.com/Seigiard/scribd-dl` | `bun install --frozen-lockfile` from the README and CI, with `bun.lock`. |
| `github.com/Seigiard/seigiard.github.io` | `bun install --frozen-lockfile` from the README and CI, with `bun.lock`. |
| `github.com/Seigiard/sync-engine` | `bun install --frozen-lockfile`, with `bun.lock` and the Bun prerequisite in `AGENTS.md`. |
| `github.com/Seigiard/ttrpg-map-viewer` | `bun install --frozen-lockfile` from the repository instructions and CI, with `bun.lock`. |
| `github.com/Seigiard/ttrpg-tools` | `bun install --frozen-lockfile` from the README and CI, with `bun.lock`. Chromium remains a separate browser prerequisite. |

These five selected repositories remain without a table:

- `github.com/Seigiard/herdr-command-palette` — no project dependency
  manifest or lockfile; checks use Python, Bash, and globally installed
  Lefthook.
- `github.com/Seigiard/herdr-pane-labels` — no project dependency manifest
  or lockfile; checks use Bash, ShellCheck, and globally installed Lefthook.
- `github.com/Seigiard/homelab` — no dependency manifest or lockfile; the
  documented install flow is interactive and mutating.
- `github.com/yochaigal/kettlewright` — the supported setup is a Docker
  devcontainer that installs dependencies and applies migrations. Starting
  Docker or initializing a database is outside worktree setup.
- `github.com/Seigiard/ttrpg-typst` — tests depend on globally installed
  `tytanic` and Python, with no lock-backed project setup.

`github.com/Seigiard/dicex` is excluded from the selected policy scope at the
user's request. It has no worktree setup table.

The selected review did not install dependencies, start services or
containers, run device actions, deploy, or read secret values. Commands were
matched against each repository's manifest, lockfile, README, instructions,
or CI workflow. Existing ignored files were considered only by path,
regular-file status, and Git ignore/tracking status.

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

## Herdr app

The `my-worktree` mod handles `Cmd+Shift+N`. The keybinding passes no space
and no action, so the mod uses the focused terminal's space and folder and
asks nothing. It generates a `worktree/<adjective>-<noun>-<4 hex>` branch, the shape
Herdr's native worktrees used, and creates it from the focused checkout's `HEAD`.
After `git worktree add`, it opens the new space with one tab running
`herdr-worktree-setup-run <path> <branch>`. When setup finishes, the same tab
returns to the interactive shell. A caller that supplies `argv` starts that
program in the first tab and keeps setup in a separate tab.
The setup log is visible and has no time cap. The runner stays in the checkout
folder: the Spaces sidebar reads the
terminal's folder, so the space keeps its branch row and its place under the
repository while setup runs. A keybinding or an empty name field generates a
`worktree/<adjective>-<noun>-<4 hex>` branch and passes that branch to setup, so
fresh-base and the `herdr-generated-worktree` marker apply. A typed name,
including an existing branch, passes an empty branch field and receives no
marker. The worktree-identity component uses the marker only when its first
line is the generated branch. On the first root agent prompt, it derives one
task slug, renames that branch once, records the attribution in Git, and labels
the app space whose `folder` exactly matches the checkout root. If no root
space exists, it can use an exact `--cwd` folder match. A branch with an
upstream is declined before model work and does not label a space. Missing or
failed app commands are diagnostic-only and leave the Git result intact.

## Claude Code nested worktrees

Claude Code's `EnterWorktree` and worktree-isolated child agents use the global
`WorktreeCreate` hook. The hook creates
`<checkout>/.claude/worktrees/<name>` on `worktree-<name>`. It uses
`origin/HEAD` when that ref resolves, and otherwise uses the current `HEAD`.
It does not fetch. An unoccupied local `worktree-<name>` branch is reused with
its tip unchanged. An already registered path is returned as is; a stale
registration whose directory is gone is removed first, and other worktree
registrations stay untouched.

After Git creates the checkout, the hook invokes `setup.ts` from
`CLAUDE_WORKTREE_SETUP_PLUGIN_DIR`, exported in `~/.zshenv` and defaulting to
`~/.local/lib/herdr-worktree-setup`. It no longer queries a Herdr registry.
The hook passes the checkout path and an empty branch field. The empty field
tells the plugin to skip fresh-base and the `herdr-generated-worktree` marker,
so the new branch keeps the parent checkout's unpushed commits and
stays as generated; the identity hook only handles app-generated markers. Setup is best
effort: the hook still
returns the created path when a setup
prerequisite is missing (`setup.ts` or `bun`) or when setup fails, and prints
the reason on stderr. Untracked files
reach the checkout only through the plugin's `copy` list in `config.toml`: the
hook replaces Claude Code's default creation, including its `.worktreeinclude`
handling.

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

## Skill-created worktrees

The `implement-spec` and `pf-build` skills create ticket worktrees with plain
`git worktree add`, which runs no hook, and then run
`herdr-worktree-setup-run <path>` themselves. The empty branch field skips
fresh-base, as for the Claude Code hook, so the ticket branch stays on its
base. The checkout gets the repository's copy and setup steps, such as
`npm ci` here.

## Provenance boundary

Worktree creation is native Herdr behavior. The `my-worktree` app mod creates
the checkout and starts `herdr-worktree-setup-run`; Claude Code creates nested
worktrees through its `WorktreeCreate` hook and invokes the setup package at
`~/.local/lib/herdr-worktree-setup`. Neither path uses the retired TUI dialog,
a plugin event, or a `herdr` PATH wrapper for provenance.

## Ownership and deployment

- Chezmoi pins the reviewed `seigi.worktree-setup` package as an external at
  `~/.local/lib/herdr-worktree-setup`; the repository-keyed policy file remains
  here at `~/.config/herdr-worktree-setup/config.toml`.
- The package is independent of the retired Herdr TUI components. Applying the
  dotfiles installs the external and leaves the policy available to both
  supported callers.
- Chezmoi changes are not live from this checkout. They become active only
  after this repository is committed, synced into chezmoi's source clone, and
  applied by the user.
