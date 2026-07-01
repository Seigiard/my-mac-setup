#!/usr/bin/env bats

load 'helpers/common'

teardown() {
  [[ -n "${BATS_TEST_TMPFILE:-}" ]] && rm -f "$BATS_TEST_TMPFILE" || true
  [[ -n "${PAIR_COWORKERS:-}" ]] && rm -rf "$PAIR_COWORKERS" || true
}

# ===========================================
# install-packages script
# ===========================================

@test "install-packages script renders as valid bash" {
  skip_if_no_chezmoi
  local script="$CHEZMOI_SOURCE/.chezmoiscripts/run_onchange_after_1-install-packages.sh.tmpl"
  [[ -f "$script" ]] || skip "install-packages script not found at $script"

  BATS_TEST_TMPFILE="$(mktemp /tmp/install-packages-XXXXXX.sh)"
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" execute-template < "$script" > "$BATS_TEST_TMPFILE"
  run bash -n "$BATS_TEST_TMPFILE"
  assert_success
}

@test "install-packages script uses set -e" {
  local script="$CHEZMOI_SOURCE/.chezmoiscripts/run_onchange_after_1-install-packages.sh.tmpl"
  [[ -f "$script" ]] || skip "install-packages script not found at $script"
  run grep -q "set -e" "$script"
  assert_success
}

@test "install-packages template has no rendering errors" {
  skip_if_no_chezmoi
  local script="$CHEZMOI_SOURCE/.chezmoiscripts/run_onchange_after_1-install-packages.sh.tmpl"
  [[ -f "$script" ]] || skip "install-packages script not found at $script"
  PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" execute-template < "$script"
  assert_success
}

# ===========================================
# macOS tunes script
# ===========================================

@test "macos-tunes script exists in darwin-specific directory" {
  assert_file_exists "$CHEZMOI_SOURCE/.chezmoiscripts/darwin/run_once_after_macos-tunes.sh"
}

@test "macos-tunes script is valid bash" {
  local script="$CHEZMOI_SOURCE/.chezmoiscripts/darwin/run_once_after_macos-tunes.sh"
  run bash -n "$script"
  assert_success
}

@test "macos-tunes script uses set -e" {
  local script="$CHEZMOI_SOURCE/.chezmoiscripts/darwin/run_once_after_macos-tunes.sh"
  run grep -q "set -e" "$script"
  assert_success
}

@test "darwin scripts excluded from managed list on Linux" {
  is_linux || skip "Only relevant on Linux"
  skip_if_no_chezmoi
  PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" managed
  refute_output --partial "run_once_after_macos-tunes"
}

# ===========================================
# ask-agent skill scripts
# ===========================================

ASK_AGENT_DIR="$CHEZMOI_SOURCE/private_dot_claude/skills/ask-agent/scripts"

@test "ask-agent scripts are valid bash" {
  for s in ask.sh agents/claude.sh agents/opencode.sh agents/pi.sh; do
    run bash -n "$ASK_AGENT_DIR/$s"
    assert_success
  done
}

@test "ask.sh uses set -euo pipefail" {
  run grep -q "set -euo pipefail" "$ASK_AGENT_DIR/ask.sh"
  assert_success
}

@test "ask.sh with no args exits 2" {
  run bash "$ASK_AGENT_DIR/ask.sh"
  assert_failure 2
}

@test "ask.sh with an unknown agent exits 2 and lists the valid agents" {
  run bash "$ASK_AGENT_DIR/ask.sh" bogus "question"
  assert_failure 2
  assert_output --partial "claude opencode pi"
}

@test "ask.sh claude read-only maps to allowlist plus explicit deny" {
  local stubdir; stubdir="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*"\n' > "$stubdir/claude"
  chmod +x "$stubdir/claude"
  run env PATH="$stubdir:$PATH" HERDR_ENV="" bash "$ASK_AGENT_DIR/ask.sh" claude "hi there"
  rm -rf "$stubdir"
  assert_success
  assert_output --partial -- "-p hi there"
  assert_output --partial -- "--allowed-tools Read Grep Glob WebFetch WebSearch"
  assert_output --partial -- "--disallowed-tools Bash Edit Write"
}

# A prompt whose first token is an option (e.g. YAML frontmatter `---` or a leading
# `-`) is misparsed by the claude CLI as a flag, dropping the prompt. It must reach
# claude via stdin (`claude -p` reads the prompt from stdin), not as a -p argv value.
# `</dev/null` on run keeps the stub's `cat` from blocking in the (red) argv path.
@test "ask.sh claude routes a leading-dash prompt via stdin, not argv" {
  local stubdir; stubdir="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nprintf "ARGS[%%s]\\n" "$*"\nprintf "STDIN[%%s]" "$(cat)"\n' > "$stubdir/claude"
  chmod +x "$stubdir/claude"
  run env PATH="$stubdir:$PATH" HERDR_ENV="" bash "$ASK_AGENT_DIR/ask.sh" claude "--- look at this" </dev/null
  rm -rf "$stubdir"
  assert_success
  assert_output --partial "STDIN[--- look at this]"
  refute_output --partial -- "-p --- look at this"
  assert_output --partial -- "ARGS[-p --allowed-tools"
}

@test "ask.sh claude routes a multiline prompt via stdin" {
  local stubdir; stubdir="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nprintf "ARGS[%%s]\\n" "$*"\nprintf "STDIN[%%s]" "$(cat)"\n' > "$stubdir/claude"
  chmod +x "$stubdir/claude"
  run env PATH="$stubdir:$PATH" HERDR_ENV="" bash "$ASK_AGENT_DIR/ask.sh" claude "$(printf 'line one\nline two')" </dev/null
  rm -rf "$stubdir"
  assert_success
  assert_output --partial "STDIN[line one"
  assert_output --partial "line two]"
  refute_output --partial -- "-p line one"
}

# ===========================================
# herdr-pair skill scripts
# ===========================================

PAIR_DIR="$CHEZMOI_SOURCE/private_dot_claude/skills/herdr-pair/scripts"

# Each session test points the session store at a throwaway dir so it never
# touches the real ~/.herdr-coworkers. teardown removes PAIR_COWORKERS.
pair_new_store() {
  PAIR_COWORKERS="$(mktemp -d)"
  export HERDR_COWORKERS_DIR="$PAIR_COWORKERS"
}

@test "session.sh is valid bash" {
  run bash -n "$PAIR_DIR/session.sh"
  assert_success
}

@test "session.sh uses set -euo pipefail" {
  run grep -q "set -euo pipefail" "$PAIR_DIR/session.sh"
  assert_success
}

@test "session.sh create writes a well-formed per-tab session and prints the sid" {
  pair_new_store
  run bash "$PAIR_DIR/session.sh" create --ws wB --tab wB:tX --sid 123-abcd \
    --a-agent claude --a-pane wB:p1 --b-agent pi --b-pane wB:p2
  assert_success
  assert_output --partial "123-abcd"
  assert_file_exists "$PAIR_COWORKERS/wB/wB_tX/session.json"
  run python3 - "$PAIR_COWORKERS/wB/wB_tX/session.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert s["sid"] == "123-abcd", s
assert s["workspace_id"] == "wB", s
assert s["tab_id"] == "wB:tX", s
assert s["roles"]["a"] == {"agent_type": "claude", "pane_id": "wB:p1"}, s
assert s["roles"]["b"] == {"agent_type": "pi", "pane_id": "wB:p2"}, s
assert s["round"] == 0, s
assert s["last_status"] == {"a": None, "b": None}, s
assert s["no_progress_count"] == 0, s
assert s["workbench"] == {"tab_id": None, "server_pane": None, "logs_pane": None}, s
assert "created_at" in s, s
PY
  assert_success
}

@test "session.sh get round-trips a created session" {
  pair_new_store
  bash "$PAIR_DIR/session.sh" create --ws wB --tab wB:tX --sid 123-abcd \
    --a-agent claude --a-pane wB:p1 --b-agent pi --b-pane wB:p2
  run bash "$PAIR_DIR/session.sh" get --ws wB --tab wB:tX
  assert_success
  assert_output --partial '"sid": "123-abcd"'
  assert_output --partial '"agent_type": "pi"'
}

@test "session.sh create refuses to clobber an existing session for the same tab" {
  pair_new_store
  bash "$PAIR_DIR/session.sh" create --ws wB --tab wB:tX --sid one \
    --a-agent claude --a-pane p1 --b-agent pi --b-pane p2
  run bash "$PAIR_DIR/session.sh" create --ws wB --tab wB:tX --sid two \
    --a-agent claude --a-pane p1 --b-agent pi --b-pane p2
  assert_failure
  run bash "$PAIR_DIR/session.sh" get --ws wB --tab wB:tX
  assert_output --partial '"sid": "one"'
}

@test "session.sh update bumps round and sets last_status, preserving prior fields" {
  pair_new_store
  bash "$PAIR_DIR/session.sh" create --ws wB --tab wB:tX --sid s \
    --a-agent claude --a-pane p1 --b-agent pi --b-pane p2
  bash "$PAIR_DIR/session.sh" update --ws wB --tab wB:tX --role a --status task
  bash "$PAIR_DIR/session.sh" update --ws wB --tab wB:tX --role b --status review
  run python3 - "$PAIR_COWORKERS/wB/wB_tX/session.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert s["round"] == 2, s
assert s["last_status"] == {"a": "task", "b": "review"}, s
assert s["roles"]["a"]["pane_id"] == "p1", s
assert s["sid"] == "s", s
PY
  assert_success
}

@test "session.sh update adjusts no_progress_count with inc and reset" {
  pair_new_store
  bash "$PAIR_DIR/session.sh" create --ws wB --tab wB:tX --sid s \
    --a-agent claude --a-pane p1 --b-agent pi --b-pane p2
  bash "$PAIR_DIR/session.sh" update --ws wB --tab wB:tX --role a --status review --no-progress inc
  bash "$PAIR_DIR/session.sh" update --ws wB --tab wB:tX --role b --status review --no-progress inc
  run python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["no_progress_count"])' "$PAIR_COWORKERS/wB/wB_tX/session.json"
  assert_output "2"
  bash "$PAIR_DIR/session.sh" update --ws wB --tab wB:tX --role a --status task --no-progress reset
  run python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["no_progress_count"])' "$PAIR_COWORKERS/wB/wB_tX/session.json"
  assert_output "0"
}

@test "session.sh flattens ':' in tab id to '_' in the on-disk path" {
  pair_new_store
  bash "$PAIR_DIR/session.sh" create --ws wB --tab "wB:t9" --sid s \
    --a-agent claude --a-pane p1 --b-agent pi --b-pane p2
  assert_file_exists "$PAIR_COWORKERS/wB/wB_t9/session.json"
  assert_file_not_exists "$PAIR_COWORKERS/wB/wB:t9/session.json"
}

@test "session.sh get on a missing session fails clearly" {
  pair_new_store
  run bash "$PAIR_DIR/session.sh" get --ws wB --tab wB:tX
  assert_failure
}

@test "session.sh update on a missing session fails and invents no state" {
  pair_new_store
  run bash "$PAIR_DIR/session.sh" update --ws wB --tab wB:tX --role a --status task
  assert_failure
  assert_file_not_exists "$PAIR_COWORKERS/wB/wB_tX/session.json"
}

@test "session.sh rejects path-traversal in --ws/--tab for every subcommand" {
  pair_new_store
  # '..' must not slip past the path guard (would let `trash` rm -rf outside the store).
  run bash "$PAIR_DIR/session.sh" trash --ws ".." --tab ".."
  assert_failure 2
  run bash "$PAIR_DIR/session.sh" create --ws ".." --tab ".." --sid s \
    --a-agent claude --a-pane p1 --b-agent pi --b-pane p2
  assert_failure 2
  run bash "$PAIR_DIR/session.sh" create --ws "a/b" --tab x --sid s \
    --a-agent claude --a-pane p1 --b-agent pi --b-pane p2
  assert_failure 2
  run bash "$PAIR_DIR/session.sh" get --ws wB --tab "../../etc"
  assert_failure 2
}

@test "session.sh trash removes only this tab's session dir, leaving sibling tabs" {
  pair_new_store
  bash "$PAIR_DIR/session.sh" create --ws wB --tab wB:t1 --sid s1 \
    --a-agent claude --a-pane p1 --b-agent pi --b-pane p2
  bash "$PAIR_DIR/session.sh" create --ws wB --tab wB:t2 --sid s2 \
    --a-agent claude --a-pane p3 --b-agent pi --b-pane p4
  run bash "$PAIR_DIR/session.sh" trash --ws wB --tab wB:t1
  assert_success
  assert_dir_not_exists "$PAIR_COWORKERS/wB/wB_t1"
  assert_dir_exists "$PAIR_COWORKERS/wB/wB_t2"
}

# ===========================================
# herdr-integrations run-script
# ===========================================

HERDR_INTEGRATIONS_TMPL="$CHEZMOI_SOURCE/.chezmoiscripts/run_onchange_after_3-setup-herdr-integrations.sh.tmpl"

@test "herdr-integrations script renders to valid bash" {
  skip_if_no_chezmoi
  [[ -f "$HERDR_INTEGRATIONS_TMPL" ]] || skip "herdr-integrations script not found"
  BATS_TEST_TMPFILE="$(mktemp /tmp/herdr-integrations-XXXXXX.sh)"
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" execute-template < "$HERDR_INTEGRATIONS_TMPL" > "$BATS_TEST_TMPFILE"
  run bash -n "$BATS_TEST_TMPFILE"
  assert_success
}

@test "herdr-integrations script guards on command -v herdr and stays tolerant" {
  run grep -q "command -v herdr" "$HERDR_INTEGRATIONS_TMPL"
  assert_success
  run grep -q 'for target in claude pi opencode' "$HERDR_INTEGRATIONS_TMPL"
  assert_success
}

@test "herdr-integrations version trigger is lookPath-guarded so CI without herdr still renders" {
  run grep -q 'lookPath "herdr"' "$HERDR_INTEGRATIONS_TMPL"
  assert_success
}

@test "herdr-integrations script exits 0 and skips when herdr is absent" {
  skip_if_no_chezmoi
  [[ -f "$HERDR_INTEGRATIONS_TMPL" ]] || skip "herdr-integrations script not found"
  BATS_TEST_TMPFILE="$(mktemp /tmp/herdr-integrations-XXXXXX.sh)"
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" execute-template < "$HERDR_INTEGRATIONS_TMPL" > "$BATS_TEST_TMPFILE"
  run env PATH="/usr/bin:/bin" bash "$BATS_TEST_TMPFILE"
  assert_success
  assert_output --partial "skipping agent-state integration refresh"
}

# ===========================================
# herdr-pair transport scripts (spawn / send / recv)
# ===========================================

@test "herdr-pair transport scripts are valid bash" {
  for s in spawn-partner.sh send.sh recv.sh; do
    run bash -n "$PAIR_DIR/$s"
    assert_success
  done
}

@test "herdr-pair transport scripts use set -euo pipefail" {
  for s in spawn-partner.sh send.sh recv.sh; do
    run grep -q "set -euo pipefail" "$PAIR_DIR/$s"
    assert_success
  done
}

# Behavioral coverage for send.sh / spawn-partner.sh using a fake `herdr` on PATH, so the
# highest-risk paths (missing flag, non-agent pane, unconfirmed delivery) run in CI.

@test "send.sh with a missing required flag exits 2 naming the flag (bash-3.2 safe)" {
  stub="$(mktemp -d)"; printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/herdr"; chmod +x "$stub/herdr"
  run env PATH="$stub:$PATH" bash "$PAIR_DIR/send.sh" \
    --self-role a --partner-role b --kind task --sid s --no-session-update --body hi
  rm -rf "$stub"
  assert_failure 2
  assert_output --partial -- "--partner-pane required"
}

@test "send.sh refuses to send into a non-agent pane" {
  stub="$(mktemp -d)"
  cat > "$stub/herdr" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "pane get" ] && printf '{"result":{"pane":{"agent_status":"unknown"}}}\n'
exit 0
SH
  chmod +x "$stub/herdr"
  run env PATH="$stub:$PATH" bash "$PAIR_DIR/send.sh" \
    --partner-pane wB:p9 --self-role a --partner-role b --kind task --sid s --no-session-update --body hi
  rm -rf "$stub"
  assert_failure 1
  assert_output --partial "not a receptive agent"
}

@test "send.sh records no turn when delivery cannot be confirmed" {
  pair_new_store
  bash "$PAIR_DIR/session.sh" create --ws wB --tab wB:tX --sid s \
    --a-agent claude --a-pane p1 --b-agent pi --b-pane p2
  stub="$(mktemp -d)"
  cat > "$stub/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pane get")          printf '{"result":{"pane":{"agent_status":"idle"}}}\n' ;;  # never leaves idle
  "wait agent-status") exit 1 ;;                                                   # working-wait times out
esac
exit 0
SH
  chmod +x "$stub/herdr"
  run env PATH="$stub:$PATH" bash "$PAIR_DIR/send.sh" \
    --partner-pane p2 --self-role a --partner-role b --kind task --sid s --ws wB --tab wB:tX --body hi
  rm -rf "$stub"
  assert_failure 1
  run python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["round"])' "$PAIR_COWORKERS/wB/wB_tX/session.json"
  assert_output "0"
}

@test "spawn-partner.sh rejects an unsupported agent" {
  stub="$(mktemp -d)"; printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/herdr"; chmod +x "$stub/herdr"
  proto="$(mktemp)"; echo proto > "$proto"
  run env PATH="$stub:$PATH" bash "$PAIR_DIR/spawn-partner.sh" --agent codex --proto "$proto" --self wB:p1
  rm -rf "$stub"; rm -f "$proto"
  assert_failure 2
  assert_output --partial "unsupported agent"
}

@test "spawn-partner.sh requires --proto" {
  stub="$(mktemp -d)"; printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/herdr"; chmod +x "$stub/herdr"
  run env PATH="$stub:$PATH" bash "$PAIR_DIR/spawn-partner.sh" --agent pi --self wB:p1
  rm -rf "$stub"
  assert_failure 2
  assert_output --partial -- "--proto"
}

# recv.sh is a pure parser (text in via stdin), so its behavior is unit-testable offline.
# Fixtures mirror real pi TUI output: leading-indented lines plus trailing TUI chrome.

@test "recv.sh extracts the latest reply addressed to self and prints its kind" {
  run bash "$PAIR_DIR/recv.sh" --self-role a --partner-role b --sid probe1 <<'EOF'
 [pair a -> b kind=task sid=probe1]

 Protocol probe. Reply per protocol.

 [pair b -> a kind=ready sid=probe1]

 Received; no files edited.

────────────────────────────────────────
~/Projects/my-mac-setup (feat/herdr-pair-skill)
$0.033 (sub) 2.3%/272k (auto)
EOF
  assert_success
  assert_line --index 0 "ready"
  assert_output --partial "Received; no files edited."
  refute_output --partial "0.033"
}

@test "recv.sh tolerates a Claude Code bullet glyph prefixing the header line" {
  run bash "$PAIR_DIR/recv.sh" --self-role a --partner-role b --sid e2e-003 <<'EOF'
⏺ [pair b -> a kind=ready sid=e2e-003]

This reply confirms the pair channel works.
EOF
  assert_success
  assert_line --index 0 "ready"
}

@test "recv.sh does not match a header quoted mid-sentence as a real reply" {
  run bash "$PAIR_DIR/recv.sh" --self-role a --partner-role b --sid s1 <<'EOF'
Lead your reply with [pair b -> a kind=ready sid=s1] then prose.
EOF
  assert_failure 3
}

@test "recv.sh ignores a stale reply before the driver's last outgoing message (cursor)" {
  run bash "$PAIR_DIR/recv.sh" --self-role a --partner-role b --sid s1 <<'EOF'
[pair b -> a kind=accepted sid=s1]
stale reply from a previous turn — must be ignored
[pair a -> b kind=task sid=s1]
my latest outgoing message (the cursor)
[pair b -> a kind=ready sid=s1]
the real reply to this turn
EOF
  assert_success
  assert_line --index 0 "ready"
}

@test "recv.sh takes the first real reply after the cursor, not a header quoted in the body" {
  run bash "$PAIR_DIR/recv.sh" --self-role a --partner-role b --sid s1 <<'EOF'
[pair a -> b kind=task sid=s1]
[pair b -> a kind=ready sid=s1]
Done. For reference the accepted header looks like:
[pair b -> a kind=accepted sid=s1]
EOF
  assert_success
  assert_line --index 0 "ready"
}

@test "recv.sh ignores messages addressed to the partner, not self" {
  run bash "$PAIR_DIR/recv.sh" --self-role a --partner-role b --sid s1 <<'EOF'
[pair a -> b kind=task sid=s1]
this is my own outgoing message
EOF
  assert_failure 3
}

@test "recv.sh reports an sid mismatch as a distinct error" {
  run bash "$PAIR_DIR/recv.sh" --self-role a --partner-role b --sid expected <<'EOF'
[pair b -> a kind=ready sid=different]
body
EOF
  assert_failure 4
  assert_output --partial "sid mismatch"
}

@test "recv.sh exits 3 when there is no reply addressed to self" {
  run bash "$PAIR_DIR/recv.sh" --self-role a --partner-role b --sid s1 <<'EOF'
just some noise
no headers here
EOF
  assert_failure 3
}

# ===========================================
# herdr-pair skill structure (source tree)
# ===========================================

PAIR_SKILL="$CHEZMOI_SOURCE/private_dot_claude/skills/herdr-pair"

@test "herdr-pair skill source has all expected files" {
  assert_file_exists "$PAIR_SKILL/SKILL.md"
  assert_file_exists "$PAIR_SKILL/references/peer-protocol.md"
  assert_file_exists "$PAIR_SKILL/references/workbench-tab.md"
  assert_file_exists "$PAIR_SKILL/scripts/session.sh"
  assert_file_exists "$PAIR_SKILL/scripts/spawn-partner.sh"
  assert_file_exists "$PAIR_SKILL/scripts/send.sh"
  assert_file_exists "$PAIR_SKILL/scripts/recv.sh"
}

@test "herdr-pair SKILL.md frontmatter is valid and triggers on the pair header" {
  run python3 - "$PAIR_SKILL/SKILL.md" <<'PY'
import sys
t = open(sys.argv[1]).read()
assert t.startswith("---\n"), "no opening frontmatter fence"
end = t.index("\n---\n", 4)
fm = t[4:end]
keys = {}
for line in fm.splitlines():
    if ":" in line and not line.startswith(" "):
        k, v = line.split(":", 1)
        keys[k.strip()] = v.strip()
assert keys.get("name") == "herdr-pair", keys
assert "[pair" in keys.get("description", ""), "description must trigger on the [pair header"
assert keys.get("user-invocable") == "true", keys
PY
  assert_success
}
