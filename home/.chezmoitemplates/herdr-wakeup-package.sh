# shellcheck shell=bash
# Shared package identity and managed session-policy linkage for Herdr Wakeup.
# shellcheck disable=SC2034 # Included scripts consume these package constants.
HERDR_WAKEUP_PLUGIN_ID="herdr-wakeup"
HERDR_WAKEUP_REPO="usrivastava92/herdr-wakeup/plugin"
HERDR_WAKEUP_REF="43db0b9f88a4b1bc560593b0ce8f2a7d2a940f04"

herdr_wakeup_configure() {
  local config_dir policy socket_path session_key session_dir session_config default_socket
  local -a socket_paths
  config_dir="$(herdr plugin config-dir "$HERDR_WAKEUP_PLUGIN_ID" </dev/null 2>/dev/null)" || return 1
  policy="$config_dir/config.json"
  [[ -f "$policy" ]] || return 1
  default_socket="$HOME/.config/herdr/herdr.sock"
  socket_paths=("$default_socket")
  if [[ -n "${HERDR_SOCKET_PATH:-}" && "$HERDR_SOCKET_PATH" != "$default_socket" ]]; then
    socket_paths+=("$HERDR_SOCKET_PATH")
  fi

  for socket_path in "${socket_paths[@]}"; do
    session_key="$(python3 - "$socket_path" <<'PY'
import sys

value = 0xcbf29ce484222325
for byte in sys.argv[1].encode():
    value = ((value ^ byte) * 0x100000001b3) & 0xffffffffffffffff
print(f"{value:016x}")
PY
)" || return 1
    session_dir="$config_dir/sessions/$session_key"
    session_config="$session_dir/config.json"
    mkdir -p "$session_dir" || return 1
    rm -f "$session_config" || return 1
    ln -s "$policy" "$session_config" || return 1
  done
}
