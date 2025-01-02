#!/usr/bin/env bash

## INSTALL BREW
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

## INSTALL ZSH
brew install zsh
## INSTALL ZIM
curl -fsSL https://raw.githubusercontent.com/zimfw/install/master/install.zsh | zsh

# Install Node using NVM.
curl -o- https://raw.githubusercontent.com/creationix/nvm/v0.34.0/install.sh | zsh
nvm install node

## Fonts
brew tap homebrew/cask-fonts
echo 'Install Nerd Fonts: Inconsolata & JetBrains Mono'
brew install --cask font-jetbrains-mono
brew install --cask font-inconsolata
brew install --cask font-symbols-only-nerd-font

brew install --cask setapp
brew install --cask ghostty # terminal
brew install fish # shell
brew install grc # colorizer
brew install --cask marta # File Manager
brew install --cask raycast
brew install --cask hammerspoon
brew install --cask karabiner-elements
brew install yqrashawn/goku/goku

brew install --cask dropbox
# brew install --cask mtmr # my touchbar my rules
brew install --cask android-file-transfer # Transfer files from and to an Android smartphone
brew install --cask ticktick # to-do and task manager
brew install --cask transmission # torrents
brew install --cask spotify
brew install --cask notunes

brew install --cask webstorm
brew install --cask vscodium
brew install --cask obsidian

brew install --cask brave-browser # Brave Browser
brew install --cask telegram

brew install --cask vanilla # Hide icons in menu bar

# plugins for quick look
brew install qlcolorcode qlstephen qlmarkdown quicklook-json betterzip qlimagesize
sudo xattr -cr ~/Library/QuickLook/QLColorCode.qlgenerator
sudo xattr -cr ~/Library/QuickLook/QLStephen.qlgenerator
sudo xattr -cr ~/Library/QuickLook/QuickLookJSON.qlgenerator
sudo xattr -cr ~/Library/QuickLook/qlImageSize.qlgenerator
qlmanage -r
qlmanage -r cache
