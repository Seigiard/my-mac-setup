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
