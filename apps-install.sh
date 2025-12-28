#!/usr/bin/env bash

## INSTALL BREW
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

## INSTALL ZSH
brew install zsh
brew tap lazywalker/rgrc

## INSTALL OH-MY-ZSH
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

## INSTALL OH-MY-ZSH CUSTOM PLUGINS
git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
git clone https://github.com/zsh-users/zsh-history-substring-search ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-history-substring-search

brew install bat
brew install delta
brew install starship
brew install lazygit
brew install nvm
brew install rgrc

# AI Assistant tools
brew install rq
brew install ripgrep
brew install ast-grep

# Install Node using NVM
nvm install node

## Fonts
brew tap homebrew/cask-fonts
echo 'Install Nerd Fonts: Inconsolata & JetBrains Mono'
brew install --cask font-recursive-code
brew install --cask font-jetbrains-mono

brew install --cask imageoptim
brew install --cask the-unarchiver

brew install --cask setapp
brew install --cask ghostty # terminal
brew install --cask marta # File Manager
brew install --cask raycast
brew install --cask karabiner-elements
brew install yqrashawn/goku/goku

brew install --cask dropbox
# brew install --cask mtmr # my touchbar my rules
brew install --cask android-file-transfer # Transfer files from and to an Android smartphone
brew install --cask ticktick # to-do and task manager
brew install --cask transmission # torrents
brew install --cask spotify
brew install --cask notunes
brew install --cask iina # video player

brew install --cask webstorm
brew install --cask vscodium
brew install --cask zed
brew install --cask figma
brew install --cask obsidian

brew install --cask brave-browser # Brave Browser
brew install --cask floorp
brew install --cask telegram
