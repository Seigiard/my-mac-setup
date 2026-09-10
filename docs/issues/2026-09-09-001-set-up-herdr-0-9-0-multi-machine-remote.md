---
title: "Set up herdr 0.9.0 multi-machine remote"
short_description: "herdr 0.9.0 saved SSH machines: hosts are settled (server + optionally mbp2021, SSH verified), but the server belongs to the homelab repo, so the open design question is how to put this repo's herdr plugin stack and agent helpers there without duplicating sources — homelab setup-step symlinks versus a role-scoped chezmoi deploy; sidebar rows also need the machine token."
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

Hosts settled 2026-09-10: `server` (home.tailc9825c.ts.net, Ubuntu 24.04) and optionally
`mbp2021`. SSH works to both (role-based config from #190, mbp2021 user fixed in a895420,
1Password agent enabled on mbp2021).

Provisioning revised 2026-09-10: the server is owned by the `homelab` repo
(github.com/Seigiard/homelab — hand-rolled zsh config, setup steps, docker services), so a full
`chezmoi apply` of this repo there was rejected: it would overwrite homelab's managed dotfiles.
The server-side work is tracked in homelab's PLAN.md ("herdr remote") and depends on the linking
decision below.

1. ~~Verify plain `ssh <host>` works~~ — done for both hosts.
2. Design and build the my-mac-setup ↔ homelab link that puts the herdr plugin stack
   (`~/.config/herdr/plugins`), the `~/.local/bin`/`~/.local/lib` helpers, and the agent-skills
   surface on the server without duplicating sources (see Open decisions).
3. `herdr machine add <host> --label ...` interactively per host; confirm the machine connects
   and its agents appear in the local sidebar.
4. Add the `machine` token to the custom `[ui.sidebar.agents]` rows in
   `home/private_dot_config/herdr/config.toml`, optionally with a #3693 color rule per machine.
5. Smoke-check on a remote workspace: pane labels, `$branch`/`$git_status` space rows,
   command palette.

## Decision (2026-09-10): role-scoped chezmoi deploy

The linking mechanism is decided: this repo's `server` machine role deploys **only** the agent
surface (herdr plugins, `~/.local/bin`/`~/.local/lib` helpers, agent skills) via role-scoped
`.chezmoiignore`; zsh, git, and everything else on the server stays owned by homelab, whose
setup step reduces to installing chezmoi and running init/apply with `MMS_MACHINE_ROLE=server`.
The symlink-from-clone alternative was rejected because `home/` sources use chezmoi naming
(`dot_*`, `private_*`, `executable_*`, `.tmpl`) — symlinking would reimplement chezmoi's file
mapping and template rendering.

Consequence: the two repos' managed path sets must stay disjoint. One collision is already
known — this repo's `private_dot_ssh/private_config.tmpl` renders `~/.ssh/config` for the
`server` role while homelab has `07-setup-ssh-key.sh`; the implementation plan must assign
that file to exactly one owner.

## Open decisions

- Whether the macOS-only pieces of the plugin stack (focus-notify notifications, caffeinate)
  should be excluded on Linux remotes via `.chezmoiignore` or already are.
- Whether `server` needs a named `--remote-session`.
