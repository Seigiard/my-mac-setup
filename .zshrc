# Add Brew in PATH
eval "$(/opt/homebrew/bin/brew shellenv)"

# Powerlevel10k prompt theme
source $(brew --prefix)/share/powerlevel10k/powerlevel10k.zsh-theme
# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# Autosuggestions
source $(brew --prefix)/share/zsh-autosuggestions/zsh-autosuggestions.zsh
# https://github.com/marlonrichert/zsh-autocomplete
# source $(brew --prefix)/share/zsh-autocomplete/zsh-autocomplete.plugin.zsh

# Store history in ~/.zsh_history
HISTFILE=~/.zsh_history
# Share history in every terminal session
setopt SHARE_HISTORY

# The meaning of these options can be found in man page of `zshoptions`.
setopt HIST_IGNORE_ALL_DUPS  # do not put duplicated command into history list
setopt HIST_SAVE_NO_DUPS  # do not save duplicated command
setopt HIST_REDUCE_BLANKS  # remove unnecessary blanks
setopt INC_APPEND_HISTORY_TIME  # append command to history file immediately after execution
setopt EXTENDED_HISTORY  # record command start time

# show all the history stored.
alias history="fc -l 1"

# Color output
alias ls="ls -A --color=auto"
alias ll="ls -alF --color=auto"

# Search in the history
source $(brew --prefix)/share/zsh-history-substring-search/zsh-history-substring-search.zsh
# Map ↑↓ navigation
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down

# Syntax highlighting
source $(brew --prefix)/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

if [ -f /Users/seigiard/.docker/init-zsh.sh ]; then

source /Users/seigiard/.docker/init-zsh.sh || true # Added by Docker Desktop

fi;
