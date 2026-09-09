---
title: "Set up herdr 0.9.0 multi-machine remote"
short_description: "herdr 0.9.0 shipped saved SSH machines (herdr machine add): plan which hosts to add, provision each remote with this repo's Linux chezmoi path since herdr copies no plugins or config to SSH hosts, and add the machine token to the custom sidebar agent rows that suppress it."
type: "chore"
category: "herdr"
tags: ["herdr","remote","ssh"]
date: "2026-09-09"
status: "open"
priority: "medium"
---

## Why this exists

herdr 0.9.0 (released 2026-09-07, installed locally via Homebrew) shipped full multi-machine
support: `herdr machine add <ssh-host>` saves an SSH machine whose workspaces and agents appear
in the local client alongside Local, with independent reconnects and machine-scoped navigation
(herdrdev/herdr#3670). The user wants remote agents on other machines visible from the laptop's
herdr window.

Facts measured against the 0.9.0 docs (https://herdr.dev/docs/connecting-machines/) that shape
the work:

- Herdr copies **no** local plugins, config, executables, or secrets to SSH hosts. The
  herdr-pane-labels, command-palette, focus-notify, caffeinate, and worktree-setup plugins, and
  every `~/.local/bin`/`~/.local/lib` helper they call, exist on a remote only if provisioned
  there. This repo's Linux chezmoi path (`chezmoi apply` on the remote) is the intended vehicle.
- Our `[ui.sidebar.agents]` rows in `home/private_dot_config/herdr/config.toml` are custom, and
  custom rows suppress the default `machine` token that distinguishes hosts once more than one
  machine is present. The token must be added explicitly; 0.9.0's ordered text/numeric sidebar
  color rules (#3693) can color it per machine.
- Our `[ui.sidebar.spaces]` rows read `$branch`/`$git_status` published by herdr-pane-labels
  (workaround for herdrdev/herdr#2952, still open on 0.9.0). Remote workspaces show empty
  space rows until that plugin stack runs on the remote server.
- Saved-machine profiles are client-side opaque state (id, label, target, session, enabled) —
  not a chezmoi-manageable config file. Authentication stays with OpenSSH; a passphrase key must
  be in ssh-agent for background reconnects.
- `herdr machine add` must run interactively (approval prompts before installing or replacing a
  remote server; default answer is No).
- IDs and agent names are scoped per server. `herdr-child`, ask-in-herdr, and the pane-label
  daemon each talk to their own host's socket, so remote automation runs on the remote host —
  which the chezmoi provisioning already delivers.

## Scope

1. Verify plain `ssh <host>` works for each chosen host; load keys into ssh-agent.
2. Provision each remote with this repo (clone → `chezmoi apply` on the remote, the existing
   Linux path), so the herdr plugin stack and `~/.local` helpers exist there.
3. `herdr machine add <host> --label ...` interactively per host; confirm the machine connects
   and its agents appear in the local sidebar.
4. Add the `machine` token to the custom `[ui.sidebar.agents]` rows in
   `home/private_dot_config/herdr/config.toml`, optionally with a #3693 color rule per machine.
5. Smoke-check on a remote workspace: pane labels, `$branch`/`$git_status` space rows,
   command palette, focus-notify.

## Open decisions

- Which hosts to add (none are named yet), and whether any need a named `--remote-session`.
- Whether the macOS-only pieces of the plugin stack (focus-notify notifications, caffeinate)
  should be excluded on Linux remotes via `.chezmoiignore` or already are.
- Whether to wait for Herdr Cloud (announced, waitlist) for hosts without easy SSH reachability.
