# shellcheck shell=bash
# Guard for run scripts that register a local Herdr plugin from $HOME.
#
# `herdr plugin link` stores the absolute path it was given in a global
# registry, and an inherited HERDR_SOCKET_PATH routes that mutation to the
# caller's running server. An apply against a throwaway $HOME therefore writes
# a temporary path into the live registry; once the directory is gone Herdr
# keeps the entry, reports "manifest unavailable", and stops resolving the
# plugin's actions. run_onchange will not rerun until the plugin files change,
# so the broken registration survives every later apply.
# See docs/solutions/test-failures/inherited-herdr-socket-contaminates-live-plugin-registry-2026-09-05.md
#
# The account database, not $HOME, decides where the live home is: $HOME is the
# very value under suspicion. When it cannot be read the guard skips the link —
# an unlinked plugin is repaired by one command, a poisoned registry is not.

herdr_link_guard_login_home() {
  local user home=""
  user="$(id -un 2>/dev/null)" || return 1
  [ -n "$user" ] || return 1
  if command -v dscl >/dev/null 2>&1; then
    home="$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null |
      sed -n 's/^NFSHomeDirectory: //p' | head -1)"
  fi
  if [ -z "$home" ] && command -v getent >/dev/null 2>&1; then
    home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
  fi
  [ -n "$home" ] || return 1
  printf '%s\n' "$home"
}

herdr_link_guard_physical_path() {
  (cd "$1" 2>/dev/null && pwd -P) || return 1
}

# Prints why linking must be skipped and returns 0 when this $HOME is not the
# live one; returns 1 (silently) when the link may proceed.
herdr_link_guard_skip_reason() {
  local login_home current

  if [ "${MMS_DISPOSABLE_HOME:-}" = "1" ]; then
    echo "\$HOME is declared disposable (MMS_DISPOSABLE_HOME=1)"
    return 0
  fi

  login_home="$(herdr_link_guard_login_home)" || {
    echo "cannot read this account's login home from the account database"
    return 0
  }
  login_home="$(herdr_link_guard_physical_path "$login_home")" || {
    echo "this account's login home does not exist"
    return 0
  }
  current="$(herdr_link_guard_physical_path "$HOME")" || {
    echo "\$HOME ($HOME) does not exist"
    return 0
  }

  [ "$current" = "$login_home" ] && return 1

  echo "\$HOME ($current) is not the login home ($login_home)"
  return 0
}
