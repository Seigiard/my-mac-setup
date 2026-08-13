#!/usr/bin/env bats

load 'helpers/common'

teardown() {
  [[ -n "${BATS_TEST_TMPFILE:-}" ]] && rm -f "$BATS_TEST_TMPFILE" || true
  [[ -n "${PAIR_COWORKERS:-}" ]] && rm -rf "$PAIR_COWORKERS" || true
  [[ -n "${HTS_WORK:-}" ]] && rm -rf "$HTS_WORK" || true
}

# ===========================================
# Repository linting
# ===========================================

@test "shellcheck is managed by the cross-platform Brewfile" {
  assert_file_contains "$SOURCE_ROOT/private_dot_config/brewfiles/Brewfile" '^brew "shellcheck"'
}

# Docker mounts only home/ and tests/, so the repo-root Makefile is absent there.
@test "lint target propagates shellcheck failures" {
  local repo_root="$BATS_TEST_DIRNAME/.."
  [[ -f "$repo_root/Makefile" ]] || skip "repo-root Makefile is not available in this environment"

  local stubdir
  stubdir="$(mktemp -d)"
  printf '#!/bin/sh\nexit 1\n' > "$stubdir/shellcheck"
  chmod +x "$stubdir/shellcheck"

  run env PATH="$stubdir:$PATH" make -C "$repo_root" lint
  rm -rf "$stubdir"
  assert_failure
}

# ===========================================
# install-packages script
# ===========================================

@test "install-packages script renders as valid bash" {
  skip_if_no_chezmoi
  local script="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_1-install-packages.sh.tmpl"
  [[ -f "$script" ]] || skip "install-packages script not found at $script"

  BATS_TEST_TMPFILE="$(mktemp /tmp/install-packages-XXXXXX.sh)"
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" execute-template < "$script" > "$BATS_TEST_TMPFILE"
  run bash -n "$BATS_TEST_TMPFILE"
  assert_success
}

@test "install-packages script uses set -e" {
  local script="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_1-install-packages.sh.tmpl"
  [[ -f "$script" ]] || skip "install-packages script not found at $script"
  run grep -q "set -e" "$script"
  assert_success
}

@test "install-packages template has no rendering errors" {
  skip_if_no_chezmoi
  local script="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_1-install-packages.sh.tmpl"
  [[ -f "$script" ]] || skip "install-packages script not found at $script"
  PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" execute-template < "$script"
  assert_success
}

# ===========================================
# macOS tunes script
# ===========================================

@test "macos-tunes script exists in darwin-specific directory" {
  assert_file_exists "$SOURCE_ROOT/.chezmoiscripts/darwin/run_once_after_macos-tunes.sh"
}

@test "macos-tunes script is valid bash" {
  local script="$SOURCE_ROOT/.chezmoiscripts/darwin/run_once_after_macos-tunes.sh"
  run bash -n "$script"
  assert_success
}

@test "macos-tunes script uses set -e" {
  local script="$SOURCE_ROOT/.chezmoiscripts/darwin/run_once_after_macos-tunes.sh"
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

ASK_AGENT_DIR="$SOURCE_ROOT/private_dot_claude/skills/ask-agent/scripts"

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

PAIR_DIR="$SOURCE_ROOT/private_dot_claude/skills/herdr-pair/scripts"

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

HERDR_INTEGRATIONS_TMPL="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_3-setup-herdr-integrations.sh.tmpl"

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

PAIR_SKILL="$SOURCE_ROOT/private_dot_claude/skills/herdr-pair"

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

# ===========================================
# Claude Code PreToolUse hooks
# ===========================================

HOOKS_DIR="$SOURCE_ROOT/private_dot_claude/hooks"
FFF_GUARD="$HOOKS_DIR/executable_fff-grep-guard.sh"
WEBFETCH_HINT="$HOOKS_DIR/executable_webfetch-markdown-hint.sh"

@test "PreToolUse hook scripts are valid bash" {
  run bash -n "$FFF_GUARD"
  assert_success
  run bash -n "$WEBFETCH_HINT"
  assert_success
}

@test "fff-grep-guard denies a query of several bare words" {
  command -v jq >/dev/null || skip "jq not available"
  run bash "$FFF_GUARD" <<'EOF'
{"tool_name":"mcp__fff__grep","tool_input":{"query":"TODO FIXME scheduling launchd cron"}}
EOF
  assert_success
  assert_output --partial '"permissionDecision": "deny"'
  assert_output --partial "mcp__fff__multi_grep"
}

@test "fff-grep-guard stays silent on a single identifier" {
  command -v jq >/dev/null || skip "jq not available"
  run bash "$FFF_GUARD" <<'EOF'
{"tool_name":"mcp__fff__grep","tool_input":{"query":"AGENT_PROFILES"}}
EOF
  assert_success
  assert_output ""
}

# Path-scoped and glob-scoped queries were the multi-token calls that actually
# returned hits, so the guard must let them through.
@test "fff-grep-guard stays silent on a path-scoped or glob-scoped query" {
  command -v jq >/dev/null || skip "jq not available"
  run bash "$FFF_GUARD" <<'EOF'
{"tool_name":"mcp__fff__grep","tool_input":{"query":"KnowledgeContextField console/"}}
EOF
  assert_success
  assert_output ""
  run bash "$FFF_GUARD" <<'EOF'
{"tool_name":"mcp__fff__grep","tool_input":{"query":"useRouter *.tsx"}}
EOF
  assert_success
  assert_output ""
}

@test "fff-grep-guard fails open on malformed input" {
  run bash "$FFF_GUARD" <<<'not json at all'
  assert_success
  assert_output ""
}

@test "webfetch-markdown-hint adds context for a plain URL" {
  command -v jq >/dev/null || skip "jq not available"
  run bash "$WEBFETCH_HINT" <<'EOF'
{"tool_name":"WebFetch","tool_input":{"url":"https://smithers.sh/docs"}}
EOF
  assert_success
  assert_output --partial '"additionalContext"'
  assert_output --partial "/markdown-new"
  refute_output --partial "permissionDecision"
}

@test "webfetch-markdown-hint stays silent when the URL already uses markdown.new" {
  command -v jq >/dev/null || skip "jq not available"
  run bash "$WEBFETCH_HINT" <<'EOF'
{"tool_name":"WebFetch","tool_input":{"url":"https://markdown.new/https://smithers.sh/docs"}}
EOF
  assert_success
  assert_output ""
}

@test "settings template registers both PreToolUse hooks with their matchers" {
  skip_if_no_chezmoi
  local tmpl="$SOURCE_ROOT/private_dot_claude/private_settings.json.tmpl"
  BATS_TEST_TMPFILE="$(mktemp /tmp/claude-settings-XXXXXX.json)"
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" execute-template < "$tmpl" > "$BATS_TEST_TMPFILE"
  run python3 - "$BATS_TEST_TMPFILE" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
matchers = {e["matcher"]: e for e in s["hooks"]["PreToolUse"]}
assert "mcp__fff__grep" in matchers, matchers.keys()
assert "WebFetch" in matchers, matchers.keys()
assert "fff-grep-guard.sh" in matchers["mcp__fff__grep"]["hooks"][0]["command"]
assert "webfetch-markdown-hint.sh" in matchers["WebFetch"]["hooks"][0]["command"]
PY
  assert_success
}

# ===========================================
# herdr-task-sync engine
# ===========================================

HTS_ENGINE="$SOURCE_ROOT/dot_local/bin/executable_herdr-task-sync"

# Build a sandbox with a stub `herdr` that records its argv. PATH is pinned to
# the stub directory plus the system directories, so a real `pi` or `claude`
# outside them can never be reached: a missing engine is then a property of the
# test, not of the machine that runs it.
hts_setup() {
  HTS_WORK="$(mktemp -d "${BATS_TMPDIR:-/tmp}/hts.XXXXXX")"
  HTS_STUB="$HTS_WORK/stub"
  HTS_STATE="$HTS_WORK/state"
  HTS_LOG="$HTS_WORK/herdr.log"
  mkdir -p "$HTS_STUB" "$HTS_STATE"
  : > "$HTS_LOG"
  # `pane list`, `pane process-info` and `tab list` are the herdr calls whose
  # answers the engine reads back, so the stub records every call and replays a
  # fixture for those three.
  cat > "$HTS_STUB/herdr" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$HTS_LOG"
if [ "\$1" = "pane" ] && [ "\$2" = "list" ]; then
  cat "$HTS_WORK/pane-list.json" 2>/dev/null
fi
if [ "\$1" = "pane" ] && [ "\$2" = "process-info" ]; then
  cat "$HTS_WORK/proc-\$4.json" 2>/dev/null
fi
if [ "\$1" = "tab" ] && [ "\$2" = "list" ]; then
  cat "$HTS_WORK/tab-list.json" 2>/dev/null
fi
exit 0
SH
  chmod +x "$HTS_STUB/herdr"
  # jq lives outside /usr/bin on Homebrew installs (macOS and the Linux test
  # container alike), so link it in rather than widening the pinned PATH — a
  # wider PATH would also expose the real pi and claude.
  local jq_bin
  jq_bin="$(command -v jq 2>/dev/null || true)"
  [[ -n "$jq_bin" ]] && ln -s "$jq_bin" "$HTS_STUB/jq"
  return 0
}

# $1 = binary name, $2 = text printed on stdout, $3 = exit code, $4 = sleep seconds
hts_stub_engine() {
  cat > "$HTS_STUB/$1" <<SH
#!/usr/bin/env bash
cat > "$HTS_WORK/$1-stdin.txt"
sleep ${4:-0}
printf '%s\n' '$2'
exit ${3:-0}
SH
  chmod +x "$HTS_STUB/$1"
}

hts_run() {
  env PATH="$HTS_STUB:/usr/bin:/bin" \
    HERDR_ENV=1 \
    HERDR_PANE_ID=pane-1 \
    HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    HERDR_TASK_SYNC_TIMEOUT="${HTS_TIMEOUT:-5}" \
    bash "$HTS_ENGINE" "$@"
}

hts_pane_list() {
  printf '%s' "$1" > "$HTS_WORK/pane-list.json"
}

# $1 = pane id, $2 = the `pane process-info` payload the stub replays for it
hts_proc_info() {
  printf '%s' "$2" > "$HTS_WORK/proc-$1.json"
}

hts_tab_list() {
  printf '%s' "$1" > "$HTS_WORK/tab-list.json"
}

# The sweep modes carry no agent and no pane, so they run the script directly
# rather than through hts_run.
hts_sweep_run() {
  env PATH="$HTS_STUB:/usr/bin:/bin" \
    HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    HERDR_TASK_SYNC_SWEEP_INTERVAL="${HTS_SWEEP_INTERVAL:-1}" \
    bash "$HTS_ENGINE" "$@"
}

hts_wait_for_publish() {
  local i
  for i in $(seq 1 60); do
    [[ -s "$HTS_LOG" ]] && return 0
    sleep 0.25
  done
  return 1
}

# The worker logs several herdr calls in a row, so a test that reads a later
# call must wait for that call and not for the first line of the log.
hts_wait_for_call() {
  local i
  for i in $(seq 1 60); do
    grep -q "$1" "$HTS_LOG" && return 0
    sleep 0.25
  done
  return 1
}

hts_token() {
  sed -n 's/.*--token task=\([^ ]*\).*/\1/p' "$HTS_LOG" | tail -1
}

hts_pane_label() {
  sed -n "s/^pane rename ${1:-pane-1} //p" "$HTS_LOG" | tail -1
}

hts_state_file() {
  printf '%s/%s.state' "$HTS_STATE" "$1"
}

hts_state_field() {
  grep -m1 "^${2}=" "$1" | cut -d= -f2- | base64 -d
}

@test "herdr-task-sync passes bash syntax check" {
  run bash -n "$HTS_ENGINE"
  assert_success
}

@test "herdr-task-sync stays silent outside herdr" {
  hts_setup
  hts_stub_engine pi never-used 0 0
  run env -u HERDR_ENV PATH="$HTS_STUB:/usr/bin:/bin" \
    HERDR_PANE_ID=pane-1 HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    bash "$HTS_ENGINE" --agent claude --session s1 <<< 'review the cache layer'
  assert_success
  sleep 2
  assert_equal "$(cat "$HTS_LOG")" ""
}

@test "herdr-task-sync publishes the engine slug and stores it (R4, R7)" {
  hts_setup
  hts_stub_engine pi cache-review 0 0
  run hts_run --agent claude --session s1 <<< 'review the cache layer please'
  assert_success
  hts_wait_for_publish
  assert_equal "$(hts_token)" "cache-review"
  local state; state="$(hts_state_file claude-pane-1-s1)"
  assert_file_exists "$state"
  assert_equal "$(hts_state_field "$state" slug)" "cache-review"
  assert_equal "$(hts_state_field "$state" first_prompt)" "review the cache layer please"
}

# AE1: a continuation prompt must not rename the session. The model decides
# stability (KTD6), so the stub stands in for a model that repeats the name.
@test "herdr-task-sync keeps the slug on a continuation prompt (AE1)" {
  hts_setup
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_publish
  : > "$HTS_LOG"
  hts_run --agent claude --session s1 <<< 'продолжай'
  hts_wait_for_publish
  assert_equal "$(hts_token)" "cache-review"
  # The naming call sees the session's first prompt, not only the newest one.
  run cat "$HTS_WORK/pi-stdin.txt"
  assert_output --partial "Current name: cache-review"
  assert_output --partial "review the cache layer please"
}

# AE3: with no usable naming engine the pane keeps whatever it had.
@test "herdr-task-sync publishes nothing when no engine is usable (AE3, R5)" {
  hts_setup
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_publish
  local state before
  state="$(hts_state_file claude-pane-1-s1)"
  before="$(cat "$state")"

  rm -f "$HTS_STUB/pi"
  : > "$HTS_LOG"
  run hts_run --agent claude --session s1 <<< 'now fix the flaky login test'
  assert_success
  sleep 2
  assert_equal "$(cat "$HTS_LOG")" ""
  assert_equal "$(cat "$state")" "$before"
}

@test "herdr-task-sync resets the stored context on a new session id" {
  hts_setup
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_publish
  : > "$HTS_LOG"
  hts_run --agent claude --session s2 <<< 'now fix the flaky login test'
  hts_wait_for_publish
  local state; state="$(hts_state_file claude-pane-1-s2)"
  assert_equal "$(hts_state_field "$state" first_prompt)" "now fix the flaky login test"
  run cat "$HTS_WORK/pi-stdin.txt"
  assert_output --partial "Current name: (none)"
}

# R8: the adapter's call must not wait on the model.
@test "herdr-task-sync returns before the naming engine finishes (R8)" {
  hts_setup
  hts_stub_engine pi late-slug 0 4
  local start end
  start="$(date +%s)"
  run hts_run --agent claude --session s1 <<< 'a slow substantive prompt'
  end="$(date +%s)"
  assert_success
  [[ $((end - start)) -le 2 ]] || fail "entry point blocked for $((end - start))s"
  hts_wait_for_publish
  assert_equal "$(hts_token)" "late-slug"
}

# KTD8: the token reaching herdr and the sidebar is bounded whatever the model
# returns — no shell metacharacters, no ANSI escapes, no newlines. The stub's
# output normalizes to five hyphen-separated words, the engine's cap for a
# published slug; wordier output is treated as a failed naming call instead.
@test "herdr-task-sync normalizes a hostile engine slug (KTD8)" {
  hts_setup
  cat > "$HTS_STUB/pi" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '\n  cache $(touch /tmp/htspwn) \033[31mREVIEW\nsecond line\n'
SH
  chmod +x "$HTS_STUB/pi"
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_publish
  run bash -c "printf '%s' '$(hts_token)' | grep -Eq '^[a-z0-9-]{1,40}\$'"
  assert_success
  assert_file_not_exists /tmp/htspwn
}

# KTD7: a naming call that fires the agent's own hooks must not recurse.
@test "herdr-task-sync exits under the recursion guard (KTD7)" {
  hts_setup
  hts_stub_engine pi never-used 0 0
  run env PATH="$HTS_STUB:/usr/bin:/bin" HERDR_ENV=1 HERDR_PANE_ID=pane-1 \
    HERDR_TASK_SYNC_ACTIVE=1 HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    bash "$HTS_ENGINE" --agent claude --session s1 <<< 'review the cache layer'
  assert_success
  sleep 2
  assert_equal "$(cat "$HTS_LOG")" ""
}

# KTD1 chain order: pi first, claude second, then nothing.
@test "herdr-task-sync falls back to claude when pi fails (KTD1)" {
  hts_setup
  hts_stub_engine pi '' 1 0
  hts_stub_engine claude flaky-login-test 0 0
  hts_run --agent claude --session s1 <<< 'now fix the flaky login test'
  hts_wait_for_publish
  assert_equal "$(hts_token)" "flaky-login-test"
}

@test "herdr-task-sync publishes nothing when both engines time out (KTD1)" {
  hts_setup
  hts_stub_engine pi slow-one 0 5
  hts_stub_engine claude slow-two 0 5
  HTS_TIMEOUT=1 hts_run --agent claude --session s1 <<< 'a substantive prompt here'
  sleep 6
  assert_equal "$(cat "$HTS_LOG")" ""
}

@test "herdr-task-sync creates its state directory with mode 700 (KTD3)" {
  hts_setup
  rmdir "$HTS_STATE"
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_publish
  run bash -c "ls -ld '$HTS_STATE' | cut -c1-10"
  assert_output "drwx------"
}

# AE5: a resumed Claude Code session is named from its transcript, before any
# prompt arrives.
@test "herdr-task-sync names a session from its transcript (AE5)" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_stub_engine pi uploader-retry 0 0
  local transcript="$HTS_WORK/transcript.jsonl"
  {
    printf '%s\n' '{"type":"user","isMeta":true,"message":{"role":"user","content":"<command-name>/init</command-name>"}}'
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"add retry logic to the uploader"}}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}'
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"also add a test"}]}}'
  } > "$transcript"
  hts_run --agent claude --session s1 --transcript "$transcript" < /dev/null
  hts_wait_for_publish
  assert_equal "$(hts_token)" "uploader-retry"
  run cat "$HTS_WORK/pi-stdin.txt"
  assert_output --partial "add retry logic to the uploader"
  refute_output --partial "<command-name>"
}

@test "herdr-task-sync publishes nothing for an empty prompt without a transcript" {
  hts_setup
  hts_stub_engine pi never-used 0 0
  run hts_run --agent claude --session s1 < /dev/null
  assert_success
  sleep 2
  assert_equal "$(cat "$HTS_LOG")" ""
}

# AE6: the pi session-name seed path publishes without a model call.
@test "herdr-task-sync --set publishes a normalized name with no engine call (AE6)" {
  hts_setup
  hts_stub_engine pi never-used 0 0
  hts_run --agent pi --session pis1 --set 'Fix CI Flake!' < /dev/null
  hts_wait_for_publish
  assert_equal "$(hts_token)" "fix-ci-flake"
  local state; state="$(hts_state_file pi-pane-1-pis1)"
  assert_equal "$(hts_state_field "$state" slug)" "fix-ci-flake"
  assert_file_not_exists "$HTS_WORK/pi-stdin.txt"
}

# The pane label opens with a short ASCII prefix for the agent, so it renders
# the same on any terminal, patched font or not.
@test "herdr-task-sync names the pane with the agent prefix" {
  hts_setup
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_call 'pane rename'
  assert_equal "$(hts_pane_label)" "cc:cache-review"
}

# An agent outside the known set still gets a readable label: its first letter.
@test "herdr-task-sync falls back to a letter prefix for an unknown agent" {
  hts_setup
  hts_stub_engine pi cache-review 0 0
  hts_run --agent aider --session s1 <<< 'review the cache layer please'
  hts_wait_for_call 'pane rename'
  assert_equal "$(hts_pane_label)" "a:cache-review"
}

# Herdr keeps one label per tab and composes nothing itself. The engine joins
# the labels of the tab's own agent panes; another tab's panes stay out.
@test "herdr-task-sync rebuilds the tab label from the pane labels" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":"claude","label":"first"},
    {"pane_id":"pane-2","tab_id":"tab-1","agent":"pi","label":"second"},
    {"pane_id":"pane-3","tab_id":"tab-1","agent":"opencode","label":null},
    {"pane_id":"pane-4","tab_id":"tab-2","agent":"claude","label":"other tab"}]}}'
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_call 'tab rename'
  run grep -m1 '^tab rename' "$HTS_LOG"
  assert_output "tab rename tab-1 first · second"
}

# A pane with no agent is named after its command. The name belongs to the
# leader of the foreground process group (pid 200 here), not to the `node`
# child that `bun run dev` spawns and that the payload lists first.
@test "herdr-task-sync names a command pane after the process group leader" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":"claude","label":"agent-label"},
    {"pane_id":"pane-2","tab_id":"tab-1","agent":null,"label":null}]}}'
  hts_proc_info pane-2 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[
      {"pid":201,"name":"node","argv0":"node","argv":["node","-e","timer"]},
      {"pid":200,"name":"bun","argv0":"bun","argv":["bun","run","dev"]}]}}}'
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_call 'tab rename'
  assert_equal "$(hts_pane_label pane-2)" "bun run dev"
  run grep -m1 '^tab rename' "$HTS_LOG"
  assert_output "tab rename tab-1 agent-label · bun run dev"
}

# A pane whose foreground process group is its own shell runs nothing. It keeps
# its slot in the tab label under a placeholder instead of disappearing.
@test "herdr-task-sync names an idle pane with the placeholder" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":"claude","label":"agent-label"},
    {"pane_id":"pane-2","tab_id":"tab-1","agent":null,"label":"btop"}]}}'
  hts_proc_info pane-2 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[
      {"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_call 'tab rename'
  assert_equal "$(hts_pane_label pane-2)" "~"
  run grep -m1 '^tab rename' "$HTS_LOG"
  assert_output "tab rename tab-1 agent-label · ~"
}

# The naming call knows one tab and not its position, so it cannot number a
# placeholder. It leaves an all-idle tab to the sweep, which can.
@test "herdr-task-sync leaves an all-idle tab label to the sweep" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":null,"label":null}]}}'
  hts_proc_info pane-1 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[
      {"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_call 'pane rename pane-1 ~'
  sleep 1
  run cat "$HTS_LOG"
  refute_output --partial "tab rename"
}

# One pane must not eat the whole tab label, so a long command name is cut to
# 24 characters with a trailing ellipsis. Flags and paths drop out entirely.
@test "herdr-task-sync truncates a long command name" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":null,"label":null}]}}'
  hts_proc_info pane-1 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[
      {"pid":200,"name":"long","argv0":"/opt/bin/averyveryverylongcommandname",
       "argv":["/opt/bin/averyveryverylongcommandname","--flag","/tmp/path","sub"]}]}}}'
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_call 'tab rename'
  run grep -m1 '^tab rename' "$HTS_LOG"
  assert_output "tab rename tab-1 averyveryverylongcomman…"
}

# A naming call refreshes only its own tab, so a command that ends and an agent
# that quits leave a stale label behind. The sweep is the observer for both: it
# walks every tab herdr knows, not just the one that triggered it.
@test "herdr-task-sync --sweep relabels every tab" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_tab_list '{"result":{"tabs":[
    {"tab_id":"tab-1","label":"1"},
    {"tab_id":"tab-2","label":"2"}]}}'
  hts_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":"claude","label":"agent-label"},
    {"pane_id":"pane-2","tab_id":"tab-2","agent":null,"label":null}]}}'
  hts_proc_info pane-2 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[
      {"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  run hts_sweep_run --sweep
  assert_success
  run grep -c '^tab rename' "$HTS_LOG"
  assert_output "2"
  run grep '^tab rename tab-2' "$HTS_LOG"
  assert_output "tab rename tab-2 btop"
}

# The daemon sweeps every few seconds. Renaming a tab to the label it already
# carries would churn the tab row and the socket for nothing.
@test "herdr-task-sync --sweep leaves an unchanged tab label alone" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_tab_list '{"result":{"tabs":[{"tab_id":"tab-1","label":"btop"}]}}'
  hts_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":null,"label":"btop"}]}}'
  hts_proc_info pane-1 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[
      {"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  run hts_sweep_run --sweep
  assert_success
  run cat "$HTS_LOG"
  refute_output --partial "tab rename"
  refute_output --partial "pane rename"
}

# An all-idle tab is numbered instead of skipped, or its last composed label
# would outlive the pane that produced it. The number counts tabs inside one
# workspace, because a tab row shows one workspace at a time.
@test "herdr-task-sync --sweep numbers all-idle tabs per workspace" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_tab_list '{"result":{"tabs":[
    {"tab_id":"tab-1","workspace_id":"ws-1","label":"1"},
    {"tab_id":"tab-2","workspace_id":"ws-1","label":"stale name"},
    {"tab_id":"tab-3","workspace_id":"ws-2","label":"2"}]}}'
  hts_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":null,"label":null},
    {"pane_id":"pane-2","tab_id":"tab-2","agent":null,"label":null},
    {"pane_id":"pane-3","tab_id":"tab-3","agent":null,"label":null}]}}'
  hts_proc_info pane-1 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[
      {"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hts_proc_info pane-2 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[
      {"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hts_proc_info pane-3 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[
      {"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  run hts_sweep_run --sweep
  assert_success
  run grep '^tab rename' "$HTS_LOG"
  assert_line "tab rename tab-1 ~ 1"
  assert_line "tab rename tab-2 ~ 2"
  assert_line "tab rename tab-3 ~ 1"
}

# herdr fires the plugin hook on every agent state change, so the guard has to
# be cheap and exact: one daemon per machine, however often it is called.
@test "herdr-task-sync --ensure-daemon keeps a single daemon" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  sleep 30 &
  local live=$!
  mkdir -p "$HTS_STATE/sweep.lock"
  printf '%s' "$live" > "$HTS_STATE/sweep.lock/pid"
  run hts_sweep_run --ensure-daemon
  assert_success
  assert_equal "$(cat "$HTS_STATE/sweep.lock/pid")" "$live"
  kill "$live" 2>/dev/null || true
}

# A daemon killed with its herdr session leaves the lock behind. The next hook
# must clear it and start a new daemon, or labels stay frozen until a restart.
@test "herdr-task-sync --ensure-daemon replaces a dead daemon" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_tab_list '{"result":{"tabs":[{"tab_id":"tab-1","label":"1"}]}}'
  hts_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":"claude","label":"agent-label"}]}}'
  mkdir -p "$HTS_STATE/sweep.lock"
  # A pid that cannot be running: process ids are allocated from 1 upwards.
  printf '%s' "999999" > "$HTS_STATE/sweep.lock/pid"
  run hts_sweep_run --ensure-daemon
  assert_success
  hts_wait_for_call 'tab rename'
  local pid; pid="$(cat "$HTS_STATE/sweep.lock/pid" 2>/dev/null)"
  [ -n "$pid" ] && [ "$pid" != "999999" ]
  kill "$pid" 2>/dev/null || true
}

# ===========================================
# herdr-task-sync Claude Code hook
# ===========================================

HTS_HOOK="$HOOKS_DIR/executable_herdr-task-sync-hook.sh"

# Put a recording stub named `herdr-task-sync` on PATH so the hook's own
# argument handling can be checked without running the real engine.
hts_hook_setup() {
  hts_setup
  cat > "$HTS_STUB/herdr-task-sync" <<SH
#!/usr/bin/env bash
{ printf 'ARGS[%s]\n' "\$*"; printf 'STDIN[%s]\n' "\$(cat)"; } >> "$HTS_WORK/engine.log"
SH
  chmod +x "$HTS_STUB/herdr-task-sync"
}

hts_hook_run() {
  env PATH="$HTS_STUB:/usr/bin:/bin" bash "$HTS_HOOK" "$@"
}

@test "herdr-task-sync hook passes bash syntax check" {
  run bash -n "$HTS_HOOK"
  assert_success
}

# Claude Code injects a UserPromptSubmit hook's stdout into the conversation,
# so the hook must stay silent on every path. This one drives the real engine
# with HERDR_ENV unset: the guard lives there, not in the hook.
@test "herdr-task-sync hook stays silent and publishes nothing outside herdr" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  # A copy, not a symlink: the source file is mode 644 and only chezmoi's
  # `executable_` prefix makes the deployed engine executable.
  cp "$HTS_ENGINE" "$HTS_STUB/herdr-task-sync"
  chmod +x "$HTS_STUB/herdr-task-sync"
  run env -u HERDR_ENV PATH="$HTS_STUB:/usr/bin:/bin" \
    HERDR_PANE_ID=pane-1 HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    bash "$HTS_HOOK" prompt <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"s1","transcript_path":"/tmp/none.jsonl","prompt":"review the cache layer"}
EOF
  assert_success
  assert_output ""
  sleep 2
  assert_equal "$(cat "$HTS_LOG")" ""
}

@test "herdr-task-sync hook writes nothing to stdout when the engine runs" {
  command -v jq >/dev/null || skip "jq not available"
  hts_hook_setup
  run hts_hook_run prompt <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"s1","transcript_path":"/tmp/none.jsonl","prompt":"review the cache layer"}
EOF
  assert_success
  assert_output ""
}

@test "herdr-task-sync hook forwards the prompt, session, and transcript" {
  command -v jq >/dev/null || skip "jq not available"
  hts_hook_setup
  hts_hook_run prompt <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"s1","transcript_path":"/tmp/t.jsonl","prompt":"review the cache layer"}
EOF
  run cat "$HTS_WORK/engine.log"
  assert_output --partial "--agent claude --session s1 --transcript /tmp/t.jsonl"
  assert_output --partial "STDIN[review the cache layer]"
}

# KTD9: session start and pre-compact name the session from the transcript,
# with no prompt on stdin.
@test "herdr-task-sync hook calls transcript mode on session start and compact" {
  command -v jq >/dev/null || skip "jq not available"
  hts_hook_setup
  hts_hook_run session <<'EOF'
{"hook_event_name":"SessionStart","session_id":"s1","transcript_path":"/tmp/t.jsonl","source":"resume"}
EOF
  hts_hook_run compact <<'EOF'
{"hook_event_name":"PreCompact","session_id":"s1","transcript_path":"/tmp/t.jsonl","trigger":"manual"}
EOF
  run cat "$HTS_WORK/engine.log"
  assert_output --partial "--transcript /tmp/t.jsonl"
  assert_output --partial "STDIN[]"
  refute_output --partial "STDIN[review"
}

# agent_id is present only when a hook fires inside a subagent call, so the
# pane's task name never follows subagent traffic (R3).
@test "herdr-task-sync hook drops subagent traffic (R3)" {
  command -v jq >/dev/null || skip "jq not available"
  hts_hook_setup
  run hts_hook_run prompt <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"s1","agent_id":"agent-abc123","transcript_path":"/tmp/t.jsonl","prompt":"subagent prompt"}
EOF
  assert_success
  assert_file_not_exists "$HTS_WORK/engine.log"
}

@test "herdr-task-sync hook survives malformed stdin" {
  hts_hook_setup
  run hts_hook_run prompt <<< 'not json at all'
  assert_success
  assert_output ""
}

@test "settings template wires the task-sync hook to all three events" {
  skip_if_no_chezmoi
  local tmpl="$SOURCE_ROOT/private_dot_claude/private_settings.json.tmpl"
  BATS_TEST_TMPFILE="$(mktemp /tmp/claude-settings-XXXXXX.json)"
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" execute-template < "$tmpl" > "$BATS_TEST_TMPFILE"
  run python3 - "$BATS_TEST_TMPFILE" <<'PY'
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
def commands(event):
    return [h["command"] for entry in hooks[event] for h in entry["hooks"]]

for event, action in (("UserPromptSubmit", "prompt"),
                      ("SessionStart", "session"),
                      ("PreCompact", "compact")):
    matching = [c for c in commands(event) if "herdr-task-sync-hook.sh" in c]
    assert len(matching) == 1, (event, commands(event))
    assert matching[0].endswith(f"' {action}"), (event, matching[0])

# UserPromptSubmit has no matcher support; the herdr agent-state SessionStart
# hook must stay wired alongside the new one.
assert all("matcher" not in e for e in hooks["UserPromptSubmit"]), hooks["UserPromptSubmit"]
assert any("herdr-agent-state.sh" in c for c in commands("SessionStart")), commands("SessionStart")
PY
  assert_success
}

@test "se pipeline --setup-cmd lands in the workflow input JSON" {
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local plan
  plan="$(mktemp /tmp/se-dryrun-plan-XXXXXX.md)"
  printf -- '---\nartifact_contract: ce-unified-plan/v1\n---\n# t\n' > "$plan"
  run env SE_DRY_RUN=1 "$se_bin" pipeline "$plan" --setup-cmd 'bun install && bunx turbo run build --filter=@x/y'
  rm -f "$plan"
  assert_success
  assert_output --partial '"setupCmd":"bun install && bunx turbo run build --filter=@x/y"'
}

@test "se flow --dry-run lands spec path, budget, and setup-cmd in the workflow input JSON" {
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local spec
  spec="$(mktemp /tmp/se-flow-spec-XXXXXX.json)"
  printf '{"task":{"description":"x"},"repo":"/tmp/r","blocks":[{"id":"scan","block":"secret-scan","retries":0,"timeoutMs":120000}]}' > "$spec"
  run env "$se_bin" flow "$spec" --budget 12 --setup-cmd 'make setup' --dry-run
  rm -f "$spec"
  assert_success
  assert_output --partial 'workflows/se-flow.tsx'
  assert_output --partial '"budgetUsd":12'
  assert_output --partial '"setupCmd":"make setup"'
  assert_output --partial '"specPath":"'
  assert_output --partial 'se-flow-spec-'
}

@test "se flow rejects a non-numeric budget" {
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local spec
  spec="$(mktemp /tmp/se-flow-spec-XXXXXX.json)"
  printf '{}' > "$spec"
  run env "$se_bin" flow "$spec" --budget abc --dry-run
  rm -f "$spec"
  assert_failure
}

@test "se blocks --json emits the composable block catalog" {
  local smithers_dir="$SOURCE_ROOT/private_dot_claude/dot_smithers"
  local se_bin="$smithers_dir/bin/executable_se"
  run env SE_SMITHERS_DIR="$smithers_dir" "$se_bin" blocks --json
  assert_success
  assert_output --partial '"secret-scan"'
  assert_output --partial '"code-review"'
  # KTD6 JSON-Schema limitation note travels with the catalog.
  assert_output --partial 'runtime-parses'
}

# ===========================================
# morning-cleanup script
# ===========================================

@test "morning-cleanup trashes stale .omc state and stamps the day" {
  local script="$SOURCE_ROOT/dot_local/bin/executable_morning-cleanup.sh"
  local fake_home="$BATS_TEST_TMPDIR/mc-home"
  mkdir -p "$fake_home/Projects/demo/.omc"
  printf '{}' > "$fake_home/Projects/demo/.omc/state.json"
  touch -t 202001010000 "$fake_home/Projects/demo/.omc/state.json"

  run env HOME="$fake_home" MORNING_CLEANUP_NO_NOTIFY=1 bash "$script"
  assert_success
  [ ! -d "$fake_home/Projects/demo/.omc" ]
  [ -f "$fake_home/.local/state/morning-cleanup/last-run" ]
}

@test "morning-cleanup keeps a recently active .omc dir" {
  local script="$SOURCE_ROOT/dot_local/bin/executable_morning-cleanup.sh"
  local fake_home="$BATS_TEST_TMPDIR/mc-home-live"
  mkdir -p "$fake_home/Projects/demo/.omc"
  printf '{}' > "$fake_home/Projects/demo/.omc/state.json"

  run env HOME="$fake_home" MORNING_CLEANUP_NO_NOTIFY=1 bash "$script"
  assert_success
  [ -d "$fake_home/Projects/demo/.omc" ]
}

@test "morning-cleanup is a no-op on its second run of the day" {
  local script="$SOURCE_ROOT/dot_local/bin/executable_morning-cleanup.sh"
  local fake_home="$BATS_TEST_TMPDIR/mc-home-stamp"
  mkdir -p "$fake_home/Projects"
  run env HOME="$fake_home" MORNING_CLEANUP_NO_NOTIFY=1 bash "$script"
  assert_success

  mkdir -p "$fake_home/Projects/late/.omc"
  printf '{}' > "$fake_home/Projects/late/.omc/state.json"
  touch -t 202001010000 "$fake_home/Projects/late/.omc/state.json"
  run env HOME="$fake_home" MORNING_CLEANUP_NO_NOTIFY=1 bash "$script"
  assert_success
  [ -d "$fake_home/Projects/late/.omc" ]
}

@test "morning-cleanup keeps fresh trash entries" {
  local script="$SOURCE_ROOT/dot_local/bin/executable_morning-cleanup.sh"
  local fake_home="$BATS_TEST_TMPDIR/mc-home-trash"
  mkdir -p "$fake_home/Projects" "$fake_home/.scratchpad/fresh-entry"
  printf 'x' > "$fake_home/.scratchpad/fresh-entry/file"

  run env HOME="$fake_home" MORNING_CLEANUP_NO_NOTIFY=1 bash "$script"
  assert_success
  [ -d "$fake_home/.scratchpad/fresh-entry" ]
}
