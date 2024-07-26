# Set PATH, MANPATH, etc., for Homebrew.
export PATH="/usr/local/sbin:$PATH"

if [[ $(arch) == 'arm64' ]]; then
  # M1
  eval "$(/opt/homebrew/bin/brew shellenv)"
else
  # Intel
  eval "$(/usr/local/bin/brew shellenv)"
fi

PATH="$PATH:$(python3 -m site --user-base)/bin"

# Add Visual Studio Code (code)
PATH="$PATH:/Applications/Visual Studio Code.app/Contents/Resources/app/bin"

if [ -d "$HOME/adb-fastboot/platform-tools" ] ; then
  PATH="$HOME/adb-fastboot/platform-tools:$PATH"
fi
# Added by OrbStack: command-line tools and integration
source ~/.orbstack/shell/init.zsh 2>/dev/null || :
