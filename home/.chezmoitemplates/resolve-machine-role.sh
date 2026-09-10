#!/bin/sh
set -eu

config_file=$1
os=$2
state_dir=${config_file%/*}
state_file=$state_dir/machine-role
role=

if [ -r "$state_file" ]; then
  IFS= read -r role < "$state_file" || true
elif [ -n "${MMS_MACHINE_ROLE:-}" ]; then
  role=$MMS_MACHINE_ROLE
else
  if ! { : < /dev/tty; } 2>/dev/null; then
    printf '%s\n' \
      'machine role is not configured; rerun with MMS_MACHINE_ROLE=mbp2021, mbp2026, or server' >&2
    exit 1
  fi

  while [ -z "$role" ]; do
    printf '%s\n' \
      'Machine role:' \
      '  1) mbp2021' \
      '  2) mbp2026' \
      '  3) server' \
      'Choose 1, 2, or 3: ' > /dev/tty
    IFS= read -r choice < /dev/tty
    case "$choice" in
      1 | mbp2021) role=mbp2021 ;;
      2 | mbp2026) role=mbp2026 ;;
      3 | server) role=server ;;
      *) printf 'Invalid choice: %s\n' "$choice" > /dev/tty ;;
    esac
  done
fi

case "$role" in
  mbp2021 | mbp2026)
    [ "$os" = darwin ] || {
      printf 'machine role "%s" is not supported on %s\n' "$role" "$os" >&2
      exit 1
    }
    ;;
  server)
    [ "$os" = linux ] || {
      printf 'machine role "%s" is not supported on %s\n' "$role" "$os" >&2
      exit 1
    }
    ;;
  *)
    printf 'invalid machine role "%s": expected mbp2021, mbp2026, or server\n' "$role" >&2
    exit 1
    ;;
esac

if [ ! -r "$state_file" ]; then
  umask 077
  mkdir -p "$state_dir"
  temporary_file=$state_file.tmp.$$
  trap 'rm -f "$temporary_file"' EXIT HUP INT TERM
  printf '%s\n' "$role" > "$temporary_file"
  mv "$temporary_file" "$state_file"
  trap - EXIT HUP INT TERM
fi

printf '%s\n' "$role"
