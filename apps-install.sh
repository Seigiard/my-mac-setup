#!/usr/bin/env bash

## INSTALL BREW
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

## BREW TAPS
brew tap lazywalker/rgrc # for rgrc util
brew tap homebrew/cask-fonts # for font casks

## INSTALL ZSH
brew install zsh # Unix shell with powerful features

## INSTALL OH-MY-ZSH
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

## INSTALL OH-MY-ZSH CUSTOM PLUGINS
git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
git clone https://github.com/zsh-users/zsh-history-substring-search ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-history-substring-search

brew install terminal-notifier # macOS notification system
brew install bat # cat clone with syntax highlighting and git integration
brew install delta # syntax-highlighting pager for git diffs
brew install starship # cross-shell customizable prompt
brew install lazygit # terminal UI for git commands
brew install mise # polyglot version manager (replaces nvm, faster)
brew install rgrc # colorizes terminal output (grc alternative in Rust)

# AI Assistant tools
brew install gh # GitHub from the command line
brew install rq # record query - jq for binary formats (protobuf, avro, etc.)
brew install ripgrep # blazingly fast grep alternative (rg)
brew install ast-grep # structural code search/replace using AST patterns

# YAZI file manager and its dependencies
brew install yazi # blazing fast terminal file manager
brew install ouch # painless compression/decompression tool
brew install ffmpeg # video/audio processing toolkit (for yazi previews)
brew install sevenzip # 7z archive support (for yazi)
brew install jq # JSON processor (for yazi)
brew install eza # modern ls replacement with icons/colors
brew install poppler # PDF rendering library (for yazi PDF previews)
brew install fd # fast find alternative (for yazi)
brew install fzf # fuzzy finder (for yazi)
brew install zoxide # smarter cd command that learns your habits

# System monitoring & disk utilities (cross-platform)
brew install btop   # htop replacement with graphs
brew install procs  # ps replacement with tree view
brew install dust   # du replacement with visual tree
brew install duf    # df replacement with nice table
brew install resvg # SVG rendering (for yazi SVG previews)
brew install imagemagick # image manipulation tools (for yazi image previews)
brew install font-symbols-only-nerd-font # icons for terminal apps

## Fonts
echo 'Install Nerd Fonts: Inconsolata & JetBrains Mono'
brew install --cask font-recursive-code # variable monospace font with cursive italics
brew install --cask font-jetbrains-mono # developer font by JetBrains

brew install --cask imageoptim # GUI image compression tool
brew install --cask the-unarchiver # universal archive extractor

brew install --cask setapp # Mac app subscription service
brew install --cask ghostty # terminal
brew install --cask marta # File Manager
brew install --cask raycast # Spotlight replacement with extensions
brew install --cask karabiner-elements # keyboard customization tool
brew install yqrashawn/goku/goku # DSL for karabiner-elements config

brew install --cask dropbox # cloud file storage
# brew install --cask mtmr # my touchbar my rules
brew install --cask android-file-transfer # Transfer files from and to an Android smartphone
brew install --cask ticktick # to-do and task manager
brew install --cask transmission # torrents
brew install --cask spotify # music streaming service
brew install --cask notunes # prevents iTunes/Music from opening
brew install --cask iina # video player

brew install --cask webstorm # JavaScript/TypeScript IDE by JetBrains
brew install --cask vscodium # VS Code without Microsoft telemetry
brew install --cask zed # high-performance modern code editor
brew install --cask figma # collaborative design tool
brew install --cask obsidian # markdown-based knowledge base

brew install --cask brave-browser # Brave Browser
brew install --cask floorp # Firefox-based privacy browser
brew install --cask telegram # secure messaging app

# Install Node using mise
mise use --global node@lts

# YAZI
ya pkg add yazi-rs/plugins:piper
ya pkg add ndtoan96/ouch
