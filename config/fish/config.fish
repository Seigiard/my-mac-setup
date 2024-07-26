if status is-interactive
    # Commands to run in interactive sessions can go here
end

# Disable the fish greeting message
set fish_greeting ""

# Auto-switch nvm version on cd
# Requires a ~/.node-version file with a valid node version
# https://github.com/jorgebucaran/nvm.fish/pull/186
if type -q nvm
  function __nvm_auto --on-variable PWD
    # nvm use 2>/dev/null # Debug
    nvm use --silent 2>/dev/null # Comment out the silent flag for debugging
  end
  __nvm_auto
end

if test -e /Users/seigiard/.docker/init-fish.sh;
  source /Users/seigiard/.docker/init-fish.sh || true # Added by Docker Desktop
end

set -x LANG en_US.UTF-8
