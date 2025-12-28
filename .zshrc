[[ ! -f /usr/local/bin/brew ]] || eval "$(/usr/local/bin/brew shellenv)"
[[ ! -f /opt/homebrew/bin/brew ]] || eval "$(/opt/homebrew/bin/brew shellenv)"

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
ZSH_THEME=""

# Map ↑↓ navigation for history substring search
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down

# Local binaries
export PATH="$HOME/.local/bin/:$PATH"

# Prompt
if command -v starship > /dev/null 2>&1; then
  eval "$(starship init zsh)"
fi

export NVM_DIR="$HOME/.nvm"
[ -s "$(brew --prefix)/opt/nvm/nvm.sh" ] && \. "$(brew --prefix)/opt/nvm/nvm.sh" # This loads nvm
[ -s "$(brew --prefix)/opt/nvm/etc/bash_completion.d/nvm" ] && \. "$(brew --prefix)/opt/nvm/etc/bash_completion.d/nvm" # This loads nvm bash_completion


# -------------------------------------------
# Aliases
# -------------------------------------------

# rgrc colorizer (auto-colorize common commands)
command -v rgrc &>/dev/null && eval "$(rgrc --aliases)"

# Load custom aliases
[[ -f ~/.aliases ]] && source ~/.aliases

if [ -f /Users/seigiard/.docker/init-zsh.sh ]; then

source /Users/seigiard/.docker/init-zsh.sh || true # Added by Docker Desktop

fi;

# -------------------------------------------
# Zellij auto-start
# -------------------------------------------

# Auto-start zellij
# if [[ -z "$ZELLIJ" ]]; then
#     eval "$(zellij setup --generate-auto-start zsh)"
# fi
