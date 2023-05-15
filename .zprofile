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

# Add VSCodium (code)
PATH="$PATH:/Applications/VSCodium.app/Contents/Resources/app/bin"
