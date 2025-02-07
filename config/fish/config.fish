if status is-interactive
    # Commands to run in interactive sessions can go here
end

# Disable the fish greeting message
set fish_greeting ""


# Set more readable tab title
function fish_title
    # emacs' "term" is basically the only term that can't handle it.
    set -x PROMPT_PWD (prompt_pwd -d 1 -D 2)

    if not set -q INSIDE_EMACS; or string match -vq '*,term:*' -- $INSIDE_EMACS
        # If we're connected via ssh, we print the hostname.
        set -l ssh
        set -q SSH_TTY
        and set ssh "["(prompt_hostname | string sub -l 10 | string collect)"]"
        # An override for the current command is passed as the first parameter.
        # This is used by `fg` to show the true process name, among others.
        if set -q argv[1]
            echo -- $PROMPT_PWD: $ssh (string sub -l 20 -- $argv[1])
        else
            # Don't print "fish" because it's redundant
            set -l command (status current-command)
            if test "$command" = fish
                echo -- $PROMPT_PWD
            else
                echo -- $PROMPT_PWD: $ssh (string sub -l 20 -- $command)
            end
        end
    end
end

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

bind \e\x7F backward-kill-word

if test -f /Users/seigiard/.docker/init-fish.sh
    source /Users/seigiard/.docker/init-fish.sh || true # Added by Docker Desktop
end

fish_add_path /opt/homebrew/sbin

# Added by Windsurf
fish_add_path /Users/seigiard/.codeium/windsurf/bin
