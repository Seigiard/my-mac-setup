[[ ! -f /usr/local/bin/brew ]] || eval "$(/usr/local/bin/brew shellenv)"
[[ ! -f /opt/homebrew/bin/brew ]] || eval "$(/opt/homebrew/bin/brew shellenv)"

# Helpers
has() { command -v "$1" > /dev/null 2>&1; }
try_source() { [[ -s "$1" ]] && source "$1"; }
BREW_PREFIX="$(brew --prefix 2>/dev/null)"

# Oh My Zsh configuration
export ZSH="$HOME/.oh-my-zsh"
ZSH_DISABLE_COMPFIX="true"

# History
HISTSIZE=10000
SAVEHIST=10000
HISTFILE=~/.zsh_history
setopt share_history
setopt appendhistory
setopt inc_append_history
setopt hist_ignore_all_dups
setopt hist_save_no_dups
setopt hist_reduce_blanks
setopt inc_append_history_time
setopt extended_history

# Oh My Zsh plugins
plugins=(
  git
  zsh-autosuggestions
  zsh-syntax-highlighting
  zsh-history-substring-search
)

source $ZSH/oh-my-zsh.sh
ZSH_THEME="" # use starship instead

# Prompt
has starship && eval "$(starship init zsh)"

# Map ↑↓ navigation for history substring search
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down

# Local binaries
export PATH="$HOME/.local/bin/:$PATH"

# NVM
export NVM_DIR="$HOME/.nvm"
try_source "$BREW_PREFIX/opt/nvm/nvm.sh"
try_source "$BREW_PREFIX/opt/nvm/etc/bash_completion.d/nvm"

# -------------------------------------------
# Aliases
# -------------------------------------------

has rgrc && eval "$(rgrc --aliases)" # colorize common commands
has zoxide && eval "$(zoxide init zsh)" # fuzzy cd
try_source ~/.aliases

# -------------------------------------------
# Docker and OrbStack
# -------------------------------------------

if [ -f /Users/seigiard/.docker/init-zsh.sh ]; then

source /Users/seigiard/.docker/init-zsh.sh || true # Added by Docker Desktop

fi;

if [ -f ~/.orbstack/shell/init.zsh ]; then

# Added by OrbStack: command-line tools and integration
# This won't be added again if you remove it.
source ~/.orbstack/shell/init.zsh 2>/dev/null || :

fi;

# -------------------------------------------
# Zellij autostart
# -------------------------------------------
# has zellij && eval "$(zellij setup --generate-auto-start zsh)"
