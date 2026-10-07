# My Mac Setup

Cross-platform dotfiles managed with [chezmoi](https://www.chezmoi.io/).

## Requirements

Check that `python3` is on your `PATH` and reports at least **3.9**. It is the
interpreter of the herdr command palette, and `chezmoi apply` shells out to it
while it runs — this repo does not install it, so a machine without one is
broken rather than merely missing a convenience.

- **macOS** — `/usr/bin/python3` ships behind the Xcode Command Line Tools that
  Homebrew already requires. It is 3.9.6, the oldest interpreter any supported
  environment provides, which is where the 3.9 floor comes from.
- **Linux** — Ubuntu and Debian ship `python3` in a normal install. Minimal
  container images often do not: this repo's own `docker/Dockerfile.ubuntu`
  has to `apt-get install -y python3` for exactly that reason.

## Quick Start (new machine)

### 1. Install Homebrew

Go to https://brew.sh/ and run the install command. Follow its prompt to add Homebrew to your `PATH`.

### 2. Install chezmoi

```sh
brew install chezmoi
```

### 3. Set up the machine's SSH key

The repo is cloned over SSH, so you need a key before chezmoi can pull it. The
managed SSH config expects the key of this machine's role at `~/.ssh/<role>`
(`mbp2026` or `mbp2021`), with no passphrase:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/<role> -N "" -C "SSH <role>"
```

Register the public key on GitHub ([how](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account))
and verify it works: `ssh -i ~/.ssh/<role> -T git@github.com`. If the key is
new, also replace the role's public key and `authorized_keys` entries as
described in [`docs/machine-secrets.md`](docs/machine-secrets.md).

### 4. Enroll the machine for secrets (optional)

API keys reach `~/.zshenv` from one age-encrypted file in this repo, decrypted
with a key that lives only on this machine. Without that key chezmoi still
applies; the shell just has no API keys. Enrollment is a two-sided step, done
from an already enrolled laptop: see
[`docs/machine-secrets.md`](docs/machine-secrets.md).

### 5. Bootstrap with chezmoi

One command clones the repo and applies everything:

```sh
chezmoi init --apply git@github.com:Seigiard/my-mac-setup.git
```

chezmoi clones into `~/.local/share/chezmoi` (it reads `.chezmoiroot = home` automatically), prompts for your name, email, and machine role, then:

- Installs Homebrew (if not present)
- Installs CLI tools and apps via Brewfiles
- Installs Oh My Zsh and plugins
- Applies macOS system preferences
- Sets up all configs (zsh, git, starship, yazi, etc.)

## Repository checks

Run `make lint` to check shell scripts, YAML files, and Markdown YAML frontmatter.
Run `npm ci` first to install the check tools. `make lint-yaml` runs only the YAML
checks: remark-lint-frontmatter-validation validates Markdown frontmatter, and
ESLint with eslint-plugin-yml validates YAML files.
Chezmoi `.tmpl` sources are excluded from these source checks.

Run `make install-git-hooks` once per clone to install hooks with simple-git-hooks.
Before commit, nano-staged runs the matching checks for staged Markdown and YAML
paths. Before push, all source YAML and frontmatter checks run against the working
tree. CI runs the same checks through `make lint`. Add new file patterns and
commands to the `nano-staged` section in `package.json` as checks grow.

Herdr installs these dependencies in new worktrees through `npm ci`. Run it
manually in worktrees created outside Herdr. `make lint-shell` runs the shell
checks without npm dependencies.

Nano-staged 1.0.2 preserves partial content edits, but does not hide unstaged
file-type changes. Stage regular-file/symlink replacements explicitly before
committing so the hook does not add a replacement you intended to leave unstaged.

## Manual Configuration

After running chezmoi, configure these manually:

### Apps

- **Raycast** — Import `*.rayconfig` backup
- **SetApp** — Install: Bartender, CleanMyMac, CleanShot X, CloudMounter

### System

- **NextDNS** — [Configure](https://my.nextdns.io)
- **Keyboard Layout** — Add [Seigiard Layout](https://github.com/Seigiard/keyboard-layout)
- **System Settings** — See `macos-settings.md` for manual tweaks

### Herdr

Chezmoi installs and enables the Command Palette from
[`Seigiard/herdr-command-palette`](https://github.com/Seigiard/herdr-command-palette)
at a reviewed commit. Personal commands stay in the managed
`~/.config/herdr/command-palette/commands.toml`; project-specific entries use a
`repositories` field in that same file. Updating the plugin means reviewing a
new package release and changing the commit pin in
`run_onchange_after_7-install-herdr-github-plugins.sh.tmpl`.

Worktree preparation is provided by the standalone
[`Seigiard/herdr-worktree-setup`](https://github.com/Seigiard/herdr-worktree-setup)
package. This repository retains its repository-keyed copy, setup-step, and
fresh-base policy in
`~/.config/herdr/plugins/config/seigi.worktree-setup/config.toml`; the package
owns the event handler, manifest, implementation tests, documentation, CI, and
releases. The generated-worktree marker written by the package is the
authorization boundary consumed by `herdr-worktree-identity`.

Pane and tab labels, agent aliases, workspace origin, and Git location/status
metadata are provided by the standalone
[`Seigiard/herdr-pane-labels`](https://github.com/Seigiard/herdr-pane-labels)
package. It owns the reconciler, alias policy, sweep daemon, manifest,
diagnostics, lifecycle, implementation tests, documentation, CI, and releases.
This repository retains only the sidebar rows and personal presentation
settings in `~/.config/herdr/config.toml`; `herdr-child` and `herdr-peer-alias`
consume the package's `herdr-pane-labels --alias-candidates` interface.

On macOS, chezmoi also installs
[`usrivastava92/herdr-wakeup`](https://github.com/usrivastava92/herdr-wakeup)
at a reviewed commit. Its managed policy keeps the Mac and display awake while
an agent works, then retains the assertion for 20 minutes after the final agent
goes quiet. Updating it uses the same reviewed-pin policy; implementation and
behavioral tests stay upstream.

### Role-based SSH access

The managed roles and aliases are:

| Role | Host | SSH user | Aliases from the other laptop |
|---|---|---|---|
| `mbp2026` | `mbp2026.tailc9825c.ts.net` | `andrew.b` | `mbp2026`, `mbp2026.local` |
| `mbp2021` | `mbp2021.tailc9825c.ts.net` | `seigiard` | `mbp2021`, `mbp2021.local` |
| `server` | `home.tailc9825c.ts.net` | `seigiard` | `server`, `home.local` |

Each laptop holds its own private key at `~/.ssh/<role>`; chezmoi renders
`~/.ssh/config`, the public keys, and the `authorized_keys` matrix from
`home/.chezmoidata/machines.yaml`. The server keeps no outbound key
(ADR-0004); attended git access from it uses a dedicated forwarded session,
`ssh -A server`. Key placement, replacement, and the enrollment of a laptop
for secrets are in [`docs/machine-secrets.md`](docs/machine-secrets.md).

Before accepting a new host-key prompt, run
`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` at the destination's local
console and compare its fingerprint with the prompt. The repository does not
manage `known_hosts`.

## Structure

```
home/
├── .chezmoiscripts/          # Install scripts (run by chezmoi)
│   ├── run_onchange_after_1-install-packages.sh.tmpl
│   ├── run_onchange_after_3-setup-herdr-integrations.sh.tmpl
│   ├── run_onchange_after_7-install-herdr-github-plugins.sh.tmpl
│   └── darwin/
│       └── run_once_after_macos-tunes.sh
├── private_dot_config/
│   ├── brewfiles/            # Homebrew packages
│   │   ├── Brewfile          # Cross-platform CLI tools
│   │   └── Brewfile.macos    # macOS apps and casks
│   ├── ghostty/
│   ├── kitty/                # kitty.conf + herdr.conf (herdr integration)
│   ├── karabiner/
│   └── yazi/
├── dot_zshenv.tmpl           # Exports API keys from the age-encrypted machine secrets
├── dot_aliases
├── dot_gitconfig.tmpl
└── ...
```

## Usage

```sh
# Update dotfiles from repo
chezmoi update

# Edit a dotfile
chezmoi edit ~/.zshrc

# See what would change
chezmoi diff

# Apply changes
chezmoi apply

# Add a new dotfile
chezmoi add ~/.config/some-app
```

## Platforms

- **macOS** — Full support (apps, system preferences, fonts)
- **Linux** — CLI tools only (via Brewfile)
