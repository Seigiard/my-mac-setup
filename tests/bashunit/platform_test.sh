#!/usr/bin/env bash
# post-apply: 40 host-safe
# platform post-apply suite — bashunit source. Vocabulary (run, assert_*,
# skip, BATS_* contract) comes from tests/bashunit/test-dsl.bash.
# Migrated from platform.bats; parity evidence: docs/benchmarks/bashunit-full-suite-experiment.md.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"


load 'helpers/common'

setup() {
  skip_if_no_chezmoi
}

# ===========================================
# .chezmoiignore platform filtering
# ===========================================

# Entries of one platform block in home/.chezmoiignore: the lines between the
# given template guard and its {{ end }}, minus comments, blanks, and the
# '/**' content globs (the bare directory entry already names the target).
# Deriving the list at runtime keeps two independent sides — the ignore file's
# own claim vs chezmoi's managed evaluation — so a newly added platform-only
# path is covered without editing this test.
chezmoiignore_block_entries() {
  local guard="$1"
  awk -v guard="$guard" '
    index($0, guard) { in_block = 1; next }
    /\{\{ end \}\}/ { in_block = 0 }
    in_block { sub(/[[:space:]]+$/, ""); print }
  ' "$SOURCE_ROOT/.chezmoiignore" | grep -v -e '^#' -e '^$' -e '/\*\*$'
}

darwin_only_entries() {
  chezmoiignore_block_entries '{{ if ne .chezmoi.os "darwin" }}'
}

linux_only_entries() {
  chezmoiignore_block_entries '{{ if ne .chezmoi.os "linux" }}'
}

function test_platform_001_chezmoiignore_filters_macos_files_on_linux() {
  _bats_test_init 1 'chezmoiignore filters macOS files on Linux'
  is_linux || skip "Only relevant on Linux"
  run chezmoi_host_partial managed --source "$SOURCE_ROOT"
  assert_success
  # Positive cross-platform control: degenerate or empty managed output
  # cannot satisfy the refutes below by accident.
  assert_output --partial ".zshenv"
  local entries entry
  entries="$(darwin_only_entries)"
  [ -n "$entries" ] || fail "no entries derived from the darwin block of .chezmoiignore"
  while IFS= read -r entry; do
    refute_output --partial "$entry"
  done <<< "$entries"
}

function test_platform_002_chezmoiignore_includes_macos_files_on_macos() {
  _bats_test_init 2 'chezmoiignore includes macOS files on macOS'
  is_macos || skip "Only relevant on macOS"
  run chezmoi_host_partial managed --source "$SOURCE_ROOT"
  assert_success
  local entries entry source_listing name asserted=0
  entries="$(darwin_only_entries)"
  [ -n "$entries" ] || fail "no entries derived from the darwin block of .chezmoiignore"
  # An ignore entry with no file in the source tree (e.g. .config/karabiner.edn)
  # cannot appear in managed output on any platform; checking the raw tree —
  # not chezmoi's evaluation — keeps the sides independent, so a broken guard
  # that wrongly ignores real entries on macOS still fails the assert below.
  source_listing="$(find "$SOURCE_ROOT" -mindepth 1)"
  while IFS= read -r entry; do
    name="${entry##*/}"
    name="${name#.}"
    case "$source_listing" in
      *"$name"*)
        assert_output --partial "$entry"
        asserted=$((asserted + 1))
        ;;
    esac
  done <<< "$entries"
  [ "$asserted" -gt 0 ] || fail "every darwin-block entry was treated as sourceless; the source-listing check is broken"
}

function test_platform_003_chezmoiignore_filters_linux_files_on_macos() {
  _bats_test_init 3 'chezmoiignore filters Linux-only files on macOS'
  is_macos || skip "Only relevant on macOS"
  run chezmoi_host_partial managed --source "$SOURCE_ROOT"
  assert_success
  # Control: the sibling darwin scripts directory survives the darwin render,
  # so an empty managed listing cannot satisfy the refutes below.
  assert_output --partial ".chezmoiscripts/darwin"
  local entries entry
  entries="$(linux_only_entries)"
  [ -n "$entries" ] || fail "no entries derived from the linux block of .chezmoiignore"
  while IFS= read -r entry; do
    refute_output --partial "$entry"
  done <<< "$entries"
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}
