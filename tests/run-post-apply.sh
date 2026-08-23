#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE' >&2
usage: tests/run-post-apply.sh full|host-safe

full      Run the complete post-apply suite against a disposable home.
host-safe Run only the files that do not execute real chezmoi apply commands.
USAGE
}

case "${1:-}" in
  full)
    set -- \
      tests/smoke.bats \
      tests/scripts.bats \
      tests/palette.bats \
      tests/platform.bats \
      tests/idempotent.bats
    ;;
  host-safe)
    set -- \
      tests/smoke.bats \
      tests/scripts.bats \
      tests/palette.bats \
      tests/platform.bats
    ;;
  *)
    usage
    exit 2
    ;;
esac

exec bats --jobs 8 --no-parallelize-across-files "$@"
