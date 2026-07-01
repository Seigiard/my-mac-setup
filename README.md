# My Mac Setup

Cross-platform dotfiles managed with [chezmoi](https://www.chezmoi.io/).

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

chezmoi clones into `~/.local/share/chezmoi` (it reads `.chezmoiroot = home` automatically), prompts for your name and email, then:

- Installs Homebrew (if not present)
- Installs CLI tools and apps via Brewfiles
- Installs Oh My Zsh and plugins
- Applies macOS system preferences
- Sets up all configs (zsh, git, starship, yazi, etc.)

## Manual Configuration

After running chezmoi, configure these manually:

### Apps

- **Raycast** — Import `*.rayconfig` backup
- **VS Codium** — Install Settings Sync extension
- **SetApp** — Install: Bartender, CleanMyMac, CleanShot X, CloudMounter

### System

- **NextDNS** — [Configure](https://my.nextdns.io)
- **Keyboard Layout** — Add [Seigiard Layout](https://github.com/Seigiard/keyboard-layout)
- **System Settings** — See `macos-settings.md` for manual tweaks

## Structure

```
home/
├── .chezmoiscripts/          # Install scripts (run by chezmoi)
│   ├── run_onchange_after_install-packages.sh.tmpl
│   └── darwin/
│       └── run_once_after_macos-tunes.sh
├── private_dot_config/
│   ├── brewfiles/            # Homebrew packages
│   │   ├── Brewfile          # Cross-platform CLI tools
│   │   └── Brewfile.macos    # macOS apps and casks
│   ├── ghostty/
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
