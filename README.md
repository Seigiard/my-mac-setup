# Clone repo

## Setup Github

- https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent
- https://docs.github.com/en/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account

# Install Apps

Open `install-apps.sh` and check, what do you need to be installed.

If you do not need something — comment it.

# Manual Settings

## NextDNS

Setup DNS: https://my.nextdns.io

## VS Codium

Install „Settings Sync“ (`Shan.code-settings-sync`) extention

- [VS Marketplace](https://marketplace.visualstudio.com/items?itemName=Shan.code-settings-sync)
- [Open VSX](https://open-vsx.org/vscode/item?itemName=Shan.code-settings-sync)

Setup and download settings.

## Visual Studio Code

Enable Settings Sync in menu

## SublimeText

Install „[Settings Sync](https://packagecontrol.io/packages/Sync%20Settings)“ extention

Setup and download settings.

Check `./config/Preferences.sublime-settings`

## RayCast

Open Raycast and import latest Raycast\*.rayconfig

# Set noTunes to launch at startup

Navigate to `System Preferences -> Users & Groups`.

Under your user, select "Login Items", click the lock on the bottom left and enter your login password to make changes. Click the plus sign (+) in the main panel and search for noTunes. Select it and click "Add".

# Seigiard Layout

Add [Seigird Layout](https://github.com/Seigiard/keyboard-layout) via Input sources

# SetApp

Install

- AlDente
- CleanMyMac
- CleanShot
- Elmedia Player
- Endurance

# Fish Shell

```sh
brew install fish
brew install grc
echo /opt/homebrew/bin/fish | sudo tee -a /etc/shells
chsh -s /opt/homebrew/bin/fish
```

In case if something goes wrong

```sh
fisher install oh-my-fish/plugin-brew # integrate Homebrew paths into shell
fisher install laughedelic/brew-completions # completions for Homebrew.
fisher install jorgebucaran/nvm.fish # node version manages
fisher install ilancosman/tide@v6 # Fish prompt line
fisher install oh-my-fish/plugin-grc # colorizer
```

Install as default

```sh
# Which fish
which fish

#  Add fish shell
echo "/usr/local/bin/fish" | sudo tee -a /etc/shells

# Make fish shell to default shell for Terminal
chsh -s /usr/local/bin/fish
```
