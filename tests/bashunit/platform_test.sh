#!/usr/bin/env bash
# post-apply: 40 host-safe
# platform post-apply suite — bashunit source. Vocabulary (run, assert_*,
# skip, BATS_* contract) comes from tests/bashunit/test-dsl.bash.
# Migrated from platform.bats; parity evidence: docs/benchmarks/bashunit-full-suite-experiment.md.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"


load 'helpers/common'

DARWIN_GUARD='{{ if ne .chezmoi.os "darwin" }}'
LINUX_GUARD='{{ if ne .chezmoi.os "linux" }}'

# The single darwin-block entry the repository provides no source for, in the
# tree or in .chezmoiexternal.toml. chezmoi cannot manage it on any platform, so
# its absence from managed output proves nothing; naming it here is what lets
# test 002 assert the other entries exactly instead of per-entry.
UNSOURCED_DARWIN_ENTRY='.config/karabiner.edn'

# Entries of one platform block in home/.chezmoiignore: the lines between the
# given template guard and its {{ end }}, minus comments, blanks, and the
# '/**' content globs (the bare directory entry already names the target).
# Deriving the list at runtime keeps two independent sides — the ignore file's
# own claim vs chezmoi's managed evaluation — so a newly added platform-only
# path is covered without editing this test.
#
# Anything else inside the block (a nested conditional, an {{ else }}, an
# indented line) means this reader no longer understands the grammar, so it
# exits non-zero instead of emitting a junk entry that every absence assertion
# below would satisfy for free.
chezmoiignore_block_entries() {
  python3 - "$SOURCE_ROOT/.chezmoiignore" "$1" <<'PY'
import sys

path, guard = sys.argv[1], sys.argv[2]
entries = []
in_block = False
for raw in open(path, encoding="utf-8").read().splitlines():
    if guard in raw:
        in_block = True
        continue
    if not in_block:
        continue
    if raw.strip() == "{{ end }}":
        break
    line = raw.rstrip()
    if not line or line.startswith("#") or line.endswith("/**"):
        continue
    if "{{" in line or line != line.strip():
        raise SystemExit(f"unexpected syntax in the {guard} block: {raw!r}")
    entries.append(line)
if not in_block:
    raise SystemExit(f"{path} has no block guarded by {guard}")
if not entries:
    raise SystemExit(f"the {guard} block of {path} names no target entries")
print("\n".join(entries))
PY
}

# Every derived entry that chezmoi manages here, either as the target itself or
# as a directory holding managed targets. Exact path membership, not substring:
# a bare basename like 'Library' would otherwise match an unrelated line.
managed_block_entries() {
  python3 - "$1" "$2" <<'PY'
import sys

entries = open(sys.argv[1], encoding="utf-8").read().splitlines()
managed = set(open(sys.argv[2], encoding="utf-8").read().splitlines())
print("\n".join(
    entry for entry in entries
    if entry in managed or any(target.startswith(entry + "/") for target in managed)
))
PY
}

# Every derived entry chezmoi does NOT manage here — the complement of the above.
unmanaged_block_entries() {
  python3 - "$1" "$2" <<'PY'
import sys

entries = open(sys.argv[1], encoding="utf-8").read().splitlines()
managed = set(open(sys.argv[2], encoding="utf-8").read().splitlines())
print("\n".join(
    entry for entry in entries
    if entry not in managed and not any(target.startswith(entry + "/") for target in managed)
))
PY
}

setup() {
  skip_if_no_chezmoi
  assert_python3_available
  PLATFORM_MANAGED="$BATS_TEST_TMPDIR/managed"
  PLATFORM_ENTRIES="$BATS_TEST_TMPDIR/entries"
}

# Capture this host's managed evaluation and one platform block's entries.
capture_platform_sides() {
  run chezmoi_host_partial managed --source "$SOURCE_ROOT"
  assert_success
  printf '%s\n' "$output" > "$PLATFORM_MANAGED"
  run chezmoiignore_block_entries "$1"
  assert_success
  printf '%s\n' "$output" > "$PLATFORM_ENTRIES"
}

# Non-degenerate-render control: one named target is managed here, judged by
# the same path membership the assertions under test use.
assert_managed_here() {
  local control="$BATS_TEST_TMPDIR/managed-control"
  printf '%s\n' "$1" > "$control"
  run managed_block_entries "$control" "$PLATFORM_MANAGED"
  assert_success
  assert_output "$1"
}

# ===========================================
# .chezmoiignore platform filtering
# ===========================================

function test_platform_001_chezmoiignore_filters_macos_files_on_linux() {
  _bats_test_init 1 'chezmoiignore filters macOS files on Linux'
  is_linux || skip "Only relevant on Linux"
  # #given this host's managed evaluation and the darwin-only ignore block
  capture_platform_sides "$DARWIN_GUARD"
  # Positive cross-platform control: degenerate or empty managed output
  # cannot satisfy the exactly-empty assertion below.
  assert_managed_here '.zshenv'
  # The refutation is load-bearing because the source tree really provides
  # these targets — this anchor proves the derived list names a sourced one,
  # so a parser that emitted junk cannot pass. Test 002 owns the other side.
  run grep -Fx '.hammerspoon' "$PLATFORM_ENTRIES"
  assert_success
  assert_output '.hammerspoon'
  assert_dir_exists "$SOURCE_ROOT/private_dot_hammerspoon"

  # #then no darwin-only entry, and nothing under one, is managed on Linux
  run managed_block_entries "$PLATFORM_ENTRIES" "$PLATFORM_MANAGED"
  assert_success
  assert_output ''
}

function test_platform_002_chezmoiignore_includes_macos_files_on_macos() {
  _bats_test_init 2 'chezmoiignore includes macOS files on macOS'
  is_macos || skip "Only relevant on macOS"
  # #given this host's managed evaluation and the darwin-only ignore block
  capture_platform_sides "$DARWIN_GUARD"

  # #then every darwin-only entry is managed here, and the only exception is
  # the one entry no source provides. A broken guard drops real entries into
  # this list; a renamed or deleted source shows up here too, instead of being
  # skipped silently.
  run unmanaged_block_entries "$PLATFORM_ENTRIES" "$PLATFORM_MANAGED"
  assert_success
  assert_output "$UNSOURCED_DARWIN_ENTRY"
}

function test_platform_003_chezmoiignore_filters_linux_files_on_macos() {
  _bats_test_init 3 'chezmoiignore filters Linux-only files on macOS'
  is_macos || skip "Only relevant on macOS"
  # #given this host's managed evaluation and the linux-only ignore block
  capture_platform_sides "$LINUX_GUARD"
  # Control: the sibling darwin scripts directory survives the darwin render,
  # so an empty managed listing cannot satisfy the assertion below.
  assert_managed_here '.chezmoiscripts/darwin'

  # #then no linux-only entry, and nothing under one, is managed on macOS.
  # Honest limit: today the linux block names only .chezmoiscripts/linux, for
  # which the tree carries no source, so this is a structural guard. It becomes
  # load-bearing with no edit here the moment a linux-only source file exists.
  run managed_block_entries "$PLATFORM_ENTRIES" "$PLATFORM_MANAGED"
  assert_success
  assert_output ''
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}
