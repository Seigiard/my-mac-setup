[[ ! -f /usr/local/bin/brew ]] || eval "$(/usr/local/bin/brew shellenv)"
[[ ! -f /opt/homebrew/bin/brew ]] || eval "$(/opt/homebrew/bin/brew shellenv)"

# History
HISTSIZE=10000
SAVEHIST=10000
# Store history in ~/.zsh_history
HISTFILE=~/.zsh_history
# Share history in every terminal session
setopt share_history
setopt appendhistory
setopt inc_append_history
setopt hist_ignore_all_dups  # do not put duplicated command into history list
setopt hist_save_no_dups  # do not save duplicated command
setopt hist_reduce_blanks  # remove unnecessary blanks
setopt inc_append_history_time  # append command to history file immediately after execution
setopt extended_history  # record command start time

autoload -U colors && colors

# Autosuggestions
source $(brew --prefix)/share/zsh-autosuggestions/zsh-autosuggestions.zsh
# Syntax highlighting
source $(brew --prefix)/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
# Search in the history
source $(brew --prefix)/share/zsh-history-substring-search/zsh-history-substring-search.zsh
# Map ↑↓ navigation
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

# show all the history stored.
alias history="fc -l 1"

# Color output
alias g='git'
alias ..='cd ..'

if command -v bat > /dev/null 2>&1; then
  alias cat='bat'
fi

alias l="ls -A --color=auto"
alias ls="ls -A --color=auto"
alias ll="ls -alF --color=auto"

if [ -f /Users/seigiard/.docker/init-zsh.sh ]; then

source /Users/seigiard/.docker/init-zsh.sh || true # Added by Docker Desktop

fi;
