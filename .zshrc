# If it is not a IntelliJ environment reader, then use fish
# if [ -z "$INTELLIJ_ENVIRONMENT_READER" ]; then
#   fish
# fi

if [ -f /Users/seigiard/.docker/init-zsh.sh ]; then
  source /Users/seigiard/.docker/init-zsh.sh || true # Added by Docker Desktop
fi;
