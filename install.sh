#!/usr/bin/env bash

## INSTALL BREW
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

## INSTALL OH-MY-ZSH
# brew install --cask zsh # zsh
# chsh -s /bin/zsh

/bin/zsh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-syntax-highlighting ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting

brew install --cask kitty # terminal
brew install --cask hammerspoon # window manager but not only
brew install --cask mtmr # my touchbar my rules
brew install --cask ticktick # to-do and task manager
brew install --cask ilya-birman-typography-layout
brew install --cask transmission # torrents
brew install --cask marta # File Manager
brew install --cask cheatsheet # Tool to list all active shortcuts of the current application

## Maybe
# brew install --cask deepl # AI translator
# brew install --cask fantastical # awesome calendar
# brew install --cask vanilla # hide icons in status bar
# brew install --cask flux # screen color temperature controller
# brew install --cask typora # Configurable document editor that supports Markdown
# brew install --cask finicky # window management\

# plugins for quick look
brew install qlcolorcode qlstephen qlmarkdown quicklook-json betterzip qlimagesize