# shellcheck shell=bash
# Shared process hygiene for detached Herdr workers.

# Agent and test harnesses can keep control pipes on descriptors above stderr.
# Detached descendants must not keep those pipes alive after their caller exits.
# Bash 3.2 reserves descriptor 255 for the running script.
close_inherited_descriptors() {
  local descriptor fd
  for descriptor in /dev/fd/*; do
    fd="${descriptor##*/}"
    case "$fd" in
      0 | 1 | 2 | 255 | *[!0-9]*) continue ;;
    esac
    eval "exec ${fd}>&-" 2>/dev/null || true
  done
}

# Prints the kernel's start timestamp for a live process, and fails when the
# process is gone. A recorded PID alone cannot identify an owner across time
# because the kernel reuses PIDs; the start timestamp makes the pair unique.
process_start_marker() {
  local pid="$1" marker
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  marker="$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null | tr -d '\n')" || return 1
  [ -n "$marker" ] || return 1
  printf '%s' "$marker"
}
