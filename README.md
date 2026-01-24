# My Mac Setup

Cross-platform dotfiles managed with [chezmoi](https://www.chezmoi.io/).

## Quick Start

```sh
# Install chezmoi and apply dotfiles
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply $PATH_TO/my-mac-setup
```

This will:

- Install Homebrew (if not present)
- Install CLI tools and apps via Brewfiles
- Install Oh My Zsh and plugins
- Apply macOS system preferences
- Set up all configs (zsh, git, starship, yazi, etc.)

## Prerequisites

Set up GitHub SSH keys:

- [Generate SSH key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent)
- [Add key to GitHub](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account)

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
├── dot_zshrc
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
