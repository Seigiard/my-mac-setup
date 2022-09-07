#!/usr/bin/env bash

## INSTALL BREW
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

## INSTALL OH-MY-ZSH

/bin/zsh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-syntax-highlighting ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting

# Install Node using NVM.
curl -o- https://raw.githubusercontent.com/creationix/nvm/v0.34.0/install.sh | bash
nvm install node

## Fonts
brew tap homebrew/cask-fonts
echo 'Install Fira Code with ligatures'
brew install --cask font-fira-code
echo 'Install Input Font'
brew install --cask font-input

brew install --cask kitty # terminal
brew install --cask hammerspoon # window manager but not only
brew install --cask mtmr # my touchbar my rules
brew install --cask android-file-transfer # Transfer files from and to an Android smartphone
brew install --cask ticktick # to-do and task manager
brew install --cask transmission # torrents
brew install --cask marta # File Manager
brew install --cask spotify
brew install --cask notunes 

brew install --cask vscodium
brew install --cask obsidian

brew install --cask brave-browser # Brave Browser
brew install --cask telegram # Telegram

brew install --cask vanilla # Hide icons in menu bar

# plugins for quick look
brew install qlcolorcode qlstephen qlmarkdown quicklook-json betterzip qlimagesize