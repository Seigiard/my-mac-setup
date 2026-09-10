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

### 2. Install chezmoi and 1Password

```sh
brew install chezmoi 1password-cli
brew install --cask 1password
```

### 3. Set up a GitHub SSH key

The repo is cloned over SSH, so you need a key before chezmoi can pull it.

- [Generate SSH key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent)
- [Add key to GitHub](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account)

Verify it works: `ssh -T git@github.com`

### 4. Enable 1Password CLI (optional, for secrets)

Some configs use 1Password to inject API keys (e.g., `LINEAR_API_KEY`).

Open the 1Password app: **Settings → Developer → Enable "Integrate with 1Password CLI"**.

Skip this and chezmoi still applies — secret templates are guarded by `lookPath "op"`, so missing 1Password just leaves those values empty.

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

The command-palette plugin files are managed by chezmoi, but registering the plugin needs a running Herdr server — which isn't up during `chezmoi apply`. After launching Herdr for the first time, link it once (the registration persists across restarts):

```bash
herdr plugin link ~/.config/herdr/plugins/command-palette
```

### Role-based SSH rollout

The managed roles and aliases are:

| Role | Host | SSH user | Aliases from the other laptop |
|---|---|---|---|
| `mbp2026` | `mbp2026.tailc9825c.ts.net` | `andrew.b` | `mbp2026`, `mbp2026.local` |
| `mbp2021` | `mbp2021.tailc9825c.ts.net` | `andrew.b` | `mbp2021`, `mbp2021.local` |
| `server` | `home.tailc9825c.ts.net` | `seigiard` | `server`, `home.local` |

Both laptops must enable the 1Password SSH Agent. Keep an existing SSH session
or local console open while adopting `authorized_keys`. Do not remove an old
key or backup until both laptops pass the checks below after a restart.

1. On each machine, update the separate chezmoi source clone to the commit that
   contains this policy.
2. Back up every existing destination before assigning its role:

   ```sh
   stamp=$(date +%Y%m%d-%H%M%S)
   for file in ~/.ssh/authorized_keys ~/.ssh/config ~/.ssh/mbp2026.pub ~/.ssh/mbp2021.pub ~/.config/1Password/ssh/agent.toml; do
     if [ -f "$file" ]; then
       cp -p "$file" "$file.before-role-ssh-$stamp"
       test -r "$file.before-role-ssh-$stamp"
     fi
   done
   ```

3. Bind the role without applying files. Use the matching command on each
   machine:

   ```sh
   MMS_MACHINE_ROLE=mbp2026 chezmoi init
   MMS_MACHINE_ROLE=mbp2021 chezmoi init
   MMS_MACHINE_ROLE=server chezmoi init
   ```

   A normal `chezmoi apply` also asks for a missing role and stores the answer in
   `~/.config/chezmoi/machine-role`. This attended rollout binds it during init
   so that authorization can be applied separately first.

4. Keep the server session open. Install inbound authorization on `server`,
   then `mbp2026`, then `mbp2021`:

   ```sh
   chezmoi diff ~/.ssh/authorized_keys
   chezmoi apply ~/.ssh/authorized_keys
   ```

   After each apply, open a fresh login from an already authorized machine. If
   it fails, restore that machine's timestamped backup from its local console.

5. On each laptop, confirm that 1Password exposes the role key. Then review and
   apply the remaining managed SSH files:

   ```sh
   SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" ssh-add -L
   chezmoi diff ~/.ssh/config ~/.ssh/mbp2026.pub ~/.ssh/mbp2021.pub ~/.config/1Password/ssh/agent.toml
   chezmoi apply ~/.ssh/config ~/.ssh/mbp2026.pub ~/.ssh/mbp2021.pub ~/.config/1Password/ssh/agent.toml
   ```

6. Before accepting a new host-key prompt, run
   `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` at the destination's local
   console and compare its fingerprint with the prompt. The repository does not
   manage `known_hosts`.
7. Run the four ordinary paths from fresh, non-multiplexed sessions:

   ```sh
   # mbp2026
   ssh -o ControlMaster=no -o ControlPath=none -o BatchMode=yes -o PreferredAuthentications=publickey mbp2021 true
   ssh -o ControlMaster=no -o ControlPath=none -o BatchMode=yes -o PreferredAuthentications=publickey server true

   # mbp2021
   ssh -o ControlMaster=no -o ControlPath=none -o BatchMode=yes -o PreferredAuthentications=publickey mbp2026 true
   ssh -o ControlMaster=no -o ControlPath=none -o BatchMode=yes -o PreferredAuthentications=publickey server true
   ```

8. From either laptop, prove that normal server sessions do not receive an
   agent. Then open the dedicated forwarded session:

   ```sh
   ssh -o ControlMaster=no -o ControlPath=none -o BatchMode=yes -o PreferredAuthentications=publickey server 'test -z "$SSH_AUTH_SOCK"'
   ssh -o ControlMaster=no -o ControlPath=none -o BatchMode=yes -o PreferredAuthentications=publickey -A server
   ```

   Inside the forwarded session, run `ssh-add -L` and a Git operation against
   an existing SSH remote. Exit that session, open another normal server
   session, and confirm that `ssh-add -L` cannot use the laptop agent.
9. Restart both laptops, unlock 1Password, and repeat one fresh managed login
   from each. Only then remove obsolete local private keys and timestamped
   backups.

## Structure

```
home/
├── .chezmoiscripts/          # Install scripts (run by chezmoi)
│   ├── run_onchange_after_1-install-packages.sh.tmpl
│   ├── run_onchange_after_2-link-herdr-command-palette.sh.tmpl
│   ├── run_onchange_after_3-setup-herdr-integrations.sh.tmpl
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
├── dot_zshrc.tmpl            # Uses 1Password for API keys
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
