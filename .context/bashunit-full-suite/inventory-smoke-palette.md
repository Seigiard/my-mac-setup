# Bats -> bashunit migration inventory: tests/smoke.bats + tests/palette.bats

Source checkout: `/Users/seigiard/Projects/my-mac-setup/.claude/worktrees/optimize-test-suite-time`
Counts verified with `grep -c '^@test'`: **smoke.bats = 74**, **palette.bats = 57** (matches expected).

---

## tests/smoke.bats (74 tests)

### 1. Test names (exact, in file order)

1. `python3 is present and at least 3.9, the floor README.md declares`
2. `repository issues CLI exposes its contract and reads checkout issues`
3. `post-apply suite wrapper rejects an unknown mode with usage`
4. `critical managed files are deployed and still managed`
5. `.gitignore ignores the agent trash directory`
6. `herdr command palette keybinding is configured`
7. `obsolete zed-herdr removal accepts formatted plugin JSON`
8. `obsolete zed-herdr removal reports malformed plugin JSON`
9. `herdr plugin updates are automatic and owner-restricted`
10. `herdr lazygit popup entrypoint is configured`
11. `herdr command palette sources are valid`
12. `herdr command palette opener detects active palette pane`
13. `herdr command palette loads TOML and project-local commands`
14. `writing-style output style is deployed and enabled in settings`
15. `pi APPEND_SYSTEM.md is deployed`
16. `pi settings include all managed packages`
17. `coding agents use terminal color palettes`
18. `opencode reads the shared writing-style file via instructions`
19. `opencode exposes curated claude skills through canonical symlinks`
20. `explicit-only workflows keep manual invocation boundaries`
21. `agent skills are deployed with their scripts and references`
22. `shared references are deployed`
23. `executor CLI resolves on PATH through ~/.local/bin (macOS only)`
24. `kitty includes its herdr bindings and keeps the Alabaster theme (macOS only)`
25. `kitty font family is one kitty accepts as monospaced (macOS only)`
26. `kitty auto-launches herdr without exec'ing it (macOS only)`
27. `kitty sends the herdr prefix for macOS-style shortcuts (macOS only)`
28. `kitty herdr bindings survive a non-Latin keyboard layout (macOS only)`
29. `kitty carries command-palette hints for the herdr plugin (macOS only)`
30. `lazygit config keeps Russian-layout keybindings and popup exit (macOS only)`
31. `herdr caffeinate plugin scripts are valid sh (macOS only)`
32. `focus-notify plugin compiles and declares its runtime entrypoint`
33. `focus-notify builds a safely quoted click command`
34. `focus-notify stays quiet for non-actionable statuses and missing pane id`
35. `focus-notify uses one notification group per pane for duplicate replacement`
36. `fzf is installed and meets the command palette's version floor`
37. `se source script exists and passes bash syntax check`
38. `se --help prints usage`
39. `se pipeline dry-run assembles smithers command with env and input JSON`
40. `se pipeline forwards the single doc-review key: absent=false, --doc-review=true`
41. `se pipeline dry-run honors --until=pr and --attach (no --detach)`
42. `se pipeline fails on nonexistent plan with reason`
43. `se pipeline fails on invalid --until value`
44. `se pipeline without --validate-cmd succeeds (derived from plan at gate-0)`
45. `se resume without runId fails with usage`
46. `se abort dry-run maps to smithers cancel`
47. `se list dry-run exits 0 and maps to smithers ps`
48. `se approve/deny/logs/chat dry-run pass through to smithers verbatim`
49. `se approve without runId fails with usage`
50. `se with unknown command fails with usage`
51. `se symlink source for ~/.local/bin exists in dotfiles`
52. `chezmoiignore excludes smithers runtime state from management`
53. `se list --json dry-run maps to smithers ps --format json`
54. `se show dry-run maps to smithers inspect --format json`
55. `se show without runId fails with usage`
56. `se show rejects run ids with shell/sql metacharacters`
57. `se usage documents list --json and show`
58. `se db-path walks up past an empty runtime smithers.db (0.28 state layout)`
59. `herdr task and child engines are deployed and executable`
60. `deployed herdr child contracts expose managed supervision modes`
61. `herdr-task-sync Claude Code hook is deployed and executable`
62. `claude settings wire the task-sync hook to prompt, session, and compact`
63. `herdr-task-sync pi extension is deployed beside herdr's own`
64. `Pi local private instructions focused tests pass`
65. `Pi brew auto updater is deployed`
66. `Pi brew auto updater focused tests pass`
67. `herdr-task-sync opencode plugin is deployed`
68. `herdr managed source preserves the U6 sidebar and ownership boundaries`
69. `herdr deployed files preserve the U6 sidebar and ownership boundaries`
70. `herdr pane-label plugin deploys the approved Herdr 0.8 lifecycle inputs`
71. `herdr pane-label plugin keeps startup sweep and relink deployment wiring`
72. `starship init output embeds no absolute PATH export`
73. `zoxide init output embeds no absolute PATH export`
74. `rgrc aliases output embeds no absolute PATH export`

### 2. Bats mechanics per group

**File-level:** `load 'helpers/common'` (loads bats-support, bats-assert, bats-file, sources disposable-home.bash; exports `CHEZMOI_BIN`, `PATH_WITHOUT_OP`, `CHEZMOI_SOURCE`, `SOURCE_ROOT`, `CHEZMOI_TEST_CONFIG`). No `setup()`, no `teardown()`, no `setup_file`/`teardown_file` in smoke.bats. File-scope top-level variables and functions (evaluated at load time in every test's bats subprocess): `FOCUS_NOTIFY_DIR`, `run_focus_notify()`, `assert_herdr_sidebar_deployment_contract()`, `SE_ROOT`, `SE_SRC`, `se_fixture_repo()`.

Groups:

- **Test 1 (python3 gate)**: calls helper `assert_python3_available` directly (no `run`); relies on bats-support `fail()` semantics: fail() prints + returns 1.
- **Tests 2-3 (repo checkout scripts)**: `run` + `assert_success` / `[ "$status" -eq 2 ]` + `assert_output` / `assert_output --partial`. Skip conditions (verbatim): `skip "repository checkout is not mounted"` guarded by `[[ -f "$repository_root/scripts/issues" ]]` and `[[ -x "$repository_root/tests/run-post-apply.sh" ]]`. Uses `$BATS_TEST_DIRNAME` to locate repo root. Test 2 runs `run bash -c 'cd "$1" && python3 scripts/issues list --status open --json' _ "$repository_root"` then feeds `$output` into a second `run python3 -c ...` (output-of-previous-run-as-argument pattern).
- **Test 4 (managed files manifest)**: bash array loop, `is_macos` OS branch, `fail` with accumulated message, `command_exists chezmoi || return 0` (soft-pass without chezmoi), invokes `PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" managed` and case-pattern membership match. No `run`.
- **Tests 5, 6, 9, 10 (grep/file-contains)**: `run grep -qx ...` + `[ "$status" -eq 0 ]`, `assert_file_contains` (bats-file), `assert_file_exists`. Read deployed `$HOME` and `$SOURCE_ROOT`.
- **Tests 7-8 (zed-herdr removal)**: build fake `uname` + `herdr` executables under `$BATS_TEST_TMPDIR/bin*`; `run env HERDR_CALLS=... PATH="$fake_bin:$PATH" bash "$script"`; assert via `run grep -Fx ... "$calls"` and `assert_output --partial`. Depends on per-test `$BATS_TEST_TMPDIR`.
- **Tests 11-13 (palette from \$HOME)**: `run python3 -m py_compile ...`, `run python3 -c ...`, heredoc `run python3 - <<'PY'` blocks. Test 12 mutates process env of the *python child* only (`os.environ.pop`). Test 13 creates its own `tmpdir="$(mktemp -d)"` and ends with `rm -rf "$tmpdir"` inside the test body (leaks if assertions abort earlier — bats tests abort on first failing command under `set -e`-like semantics).
- **Tests 14-22 (claude/pi/opencode config)**: `assert_file_exists`, `assert_file_not_exists`, `assert_dir_not_exists`, `run jq -e ...` + `assert_success`, `run readlink` + `assert_output`, `run awk '<frontmatter program>'`, `fail` on symlink presence. Test 20 additionally runs `run zsh -dfc 'unset ...; source "$1"; zsh -dfc "$2"' _ "$HOME/.zshenv" '...'` — requires zsh and a deployed `~/.zshenv`.
- **Tests 23-31 (macOS-only)**: every one begins `is_macos || skip "Not on macOS"` (verbatim). Test 23 has second skip `skip "Executor.app not installed (CI-minimal render omits the cask)"` guarded by `[ -e /Applications/Executor.app ]`; then `run "$link" --version`. Tests 24-30 are `assert_file_contains` with anchored regexes against deployed kitty/lazygit configs; test 28 also runs a grep pipeline into a variable with `|| true` and `fail`. Test 31 loops `run sh -n ...` + `[ "$status" -eq 0 ]`.
- **Tests 32-35 (focus-notify)**: use file-scope `FOCUS_NOTIFY_DIR="$SOURCE_ROOT/..."` and helper `run_focus_notify()` which writes a fake notifier script into `$BATS_TEST_TMPDIR`, sets `FOCUS_NOTIFY_ARGV` (test-global, not local), and invokes `run` *inside a helper function* with env-prefixed `run python3 ...`. Test 32 sets `PYTHONPYCACHEPREFIX="$BATS_TEST_TMPDIR/pycache"` for py_compile. Assertions: `assert_success`, `assert_file_exists`/`assert_file_not_exists` on the argv capture file, heredoc `run python3 - <args> <<'PY'` verification. Test 33 asserts shell-quoting safety of a hostile pane id, and passes `HERDR_BIN_PATH="$BATS_TEST_TMPDIR/dir with space/herdr"` (path with a space, deliberately).
- **Test 36 (fzf)**: asserts (never skips): `run command -v fzf`, `run fzf --version`, extracts `${output%% *}`, heredoc python compares against `palette.FZF_MIN_VERSION` loaded from the deployed `$HOME` palette.py.
- **Tests 37-58 (se CLI, SE_DRY_RUN)**: file-scope `SE_SRC` under `$SOURCE_ROOT`; helper `se_fixture_repo()` creates `$BATS_TEST_TMPDIR/target-repo` with a plan file. Several tests `cd "$repo"` inside the test body (working-directory mutation; safe in bats because each test is its own process). Pattern: `run env SE_DRY_RUN=1 bash "$SE_SRC" ...` + `assert_success`/`assert_failure` + `assert_output --partial` / `refute_output --partial -- "--detach"` (note the `--` separator before a leading-dash pattern). Test 48 loops `for sub in approve deny logs chat` with `run` per iteration. Test 58 uses its own `mktemp -d` + trailing `rm -rf "$tmp"`, and `SE_SMITHERS_DIR` env.
- **Tests 59-71 (herdr task sync / sidebar / pane labels)**: `assert_file_executable` (bats-file), many `assert_file_contains` regex assertions, heredoc `run python3 - "$settings" <<'PY'` for JSON hook wiring, `run bun test <file>` for tests 64 and 66 (spawns Bun test suites; test 64 also sets `PI_AGENTS_LOCAL_EXTENSION_PATH`). Tests 68-69 call shared function `assert_herdr_sidebar_deployment_contract` which itself uses `run grep -E ...` + `assert_failure` and numeric `[ ... ]` checks (note: it uses `run` inside a helper, clobbering caller's `$status/$output`). Test 70: `run awk` manifest-parse with a multi-line `assert_output $'...\n...'` (ANSI-C quoted expected string, 12 lines), plus `run grep -E ...` + `assert_failure` (asserting a pattern is absent).
- **Tests 72-74 (cached_init consumers)**: skip conditions verbatim: `command_exists starship || skip "starship not installed"`, `command_exists zoxide || skip "zoxide not installed"`, `command_exists rgrc || skip "rgrc not installed"`. Then `run <tool> ...` + `assert_success` + `refute_line --regexp '^export PATH='` (bats-assert line-wise regex refutation over `$lines`).

### 3. File-level setup functions

smoke.bats has **no** `setup`, `teardown`, `setup_file`, or `teardown_file`. File-level code executed at load time (verbatim, excluding comments):

```bash
load 'helpers/common'

FOCUS_NOTIFY_DIR="$SOURCE_ROOT/private_dot_config/herdr/plugins/herdr-focus-notify"

run_focus_notify() {
  local event_json="$1"
  local fake_bin="$BATS_TEST_TMPDIR/fake-notifier"
  FOCUS_NOTIFY_ARGV="$BATS_TEST_TMPDIR/notifier.argv"
  cat > "$fake_bin" <<SH
#!/bin/sh
printf '%s\n' "\$@" > "$FOCUS_NOTIFY_ARGV"
SH
  chmod +x "$fake_bin"
  HERDR_PLUGIN_EVENT_JSON="$event_json" \
    HERDR_FOCUS_NOTIFY_NOTIFIER_BIN="$fake_bin" \
    HERDR_BIN_PATH="$BATS_TEST_TMPDIR/dir with space/herdr" \
    run python3 "$FOCUS_NOTIFY_DIR/notify.py"
}

SE_ROOT="$SOURCE_ROOT"
SE_SRC="$SE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"

se_fixture_repo() {
  local repo="$BATS_TEST_TMPDIR/target-repo"
  mkdir -p "$repo/docs/plans"
  printf '# fixture plan\n' > "$repo/docs/plans/plan.md"
  echo "$repo"
}

assert_herdr_sidebar_deployment_contract() {
  local config="$1"
  local width

  assert_file_contains "$config" '^sidebar_min_width = 32$'
  assert_file_contains "$config" '^\[ui.sidebar.agents\]$'
  assert_file_contains "$config" '^rows = \[\["state_icon", "workspace", "pane"\], \["\$git_ref", "\$git_status"\]\]$'
  run grep -E '\$location_label|\$location_status' "$config"
  assert_failure
  width="$(awk '
    $0 == "[ui]" { in_ui = 1; next }
    /^\[/ { in_ui = 0 }
    in_ui && /^sidebar_min_width = [0-9]+$/ { print $3 }
  ' "$config")"
  [ "$width" -eq 32 ]
  [ "$((width - 4))" -ge 28 ]
  [ "$((width - 4))" -ge 8 ]
}
```

### 4. Migration hazards (smoke.bats)

- **`run` inside helper functions** (`run_focus_notify`, `assert_herdr_sidebar_deployment_contract`, `rank_*`-style patterns): bashunit's `assert_*` operate on explicit values, not implicit `$status/$output/$lines` globals set by `run`. Every call site must be rewritten to capture `output=$(cmd 2>&1); status=$?` explicitly, and the env-prefix-before-`run` form (`FOO=bar run cmd`) has no direct equivalent.
- **bats-assert vocabulary with no 1:1 bashunit equivalent**: `assert_output --partial`, `refute_output --partial -- "--detach"` (the `--` leading-dash guard), `assert_line --index N`, `refute_line --regexp`, `refute_line --partial`, multi-line `assert_output $'a\nb\nc'`. `$lines` array indexing (`assert_equal "${#lines[@]}" 1` in palette) needs manual `mapfile`-style splitting; note bats' `$lines` drops empty lines — a naive split does not.
- **bats-file assertions**: `assert_file_exists`, `assert_file_not_exists`, `assert_dir_not_exists`, `assert_file_executable`, `assert_file_contains <file> <regex>` (grep -E semantics) all need shims.
- **`fail()` semantics**: helpers rely on bats-support `fail` printing and *returning* 1 (documented in common.bash comments: it does not abort the function). `assert_python3_available` is built around this; a bashunit `fail` that exits or one that doesn't mark failure changes behavior. Related repo issue: bare mid-test assertions are silently inert in bats (commit f7153fa) — semantics differ again in bashunit, where each assertion records failure but execution continues.
- **`skip` with message**: 12 tests use conditional `skip "..."` (9 macOS-only, 3 tool-presence, 2 checkout-presence). bashunit's skip mechanism differs (`skip` exists but reporting/exit semantics differ; skip inside a helper like `skip_if_no_chezmoi`/`require_disposable_home` must propagate).
- **`$BATS_TEST_TMPDIR` / `$BATS_TMPDIR` / `$BATS_TEST_DIRNAME`**: no bashunit equivalents; need per-test unique temp dirs (create in set_up, remove in tear_down) and a script-dir variable. Under parallel execution, fixed-name temp files (test 13's bare `mktemp -d`, test 58's `$tmp`) are fine, but any migration to a *shared* temp dir would collide.
- **Working-directory mutation**: se tests `cd "$repo"` with no cd-back. Bats isolates per-test in a subprocess; bashunit runs tests in the same shell process per file (unless parallel), so a missing `cd` reset leaks into later tests. Every `cd` needs a pushd/popd or subshell.
- **PATH and env leakage**: tests prepend stub dirs to PATH via `run env PATH=...` (contained), but focus-notify sets the test-global `FOCUS_NOTIFY_ARGV` variable across helper/test boundary — in bashunit's shared-process model, stale values leak between tests (tests 33-35 depend on the file *not existing* — `assert_file_not_exists "$FOCUS_NOTIFY_ARGV"` — so a leaked path from a prior test that DID write it would flip the result unless tmpdirs are per-test).
- **Output-of-run-as-input chaining** (test 2: second `run` consumes `$output` of the first): must restructure into explicit variables.
- **`command_exists chezmoi || return 0`** (test 4): early-return-as-pass; in bashunit a bare `return 0` mid-test is fine but must not be converted into an assertion.
- **`run bun test ...`** (tests 64, 66): spawns full Bun suites; long-running; under parallel execution two Bun invocations can contend. Serialization not strictly required but they are the slowest units.
- **Load-time side effects**: `helpers/common.bash` runs `chezmoi source-path` and PATH scanning at source time and `return 1` if bats-libs are missing — in bashunit this must move to a bootstrap file; `return 1` at top level of a sourced file has different failure surfacing.
- **No inter-test ordering dependencies detected** in smoke.bats: every test builds its own fixtures. All tests are read-only against `$HOME`/`$SOURCE_ROOT` except temp-dir writes. Safe to parallelize per-test given per-test temp dirs.

### 5. External commands invoked (smoke.bats) and failure mode if absent

| Command | Tests | If absent |
|---|---|---|
| `python3` (>=3.9) | 1, 2, 11-13, 32-36, 62 | Hard fail (deliberate: declared requirement, asserts, never skips) |
| `chezmoi` | 4 (managed check), helper load-time `source-path` | Test 4 soft-passes second half (`return 0`); helpers fall back to defaults |
| `jq` | 14, 16, 17, 18 | Fail (`run jq` -> 127, assert_success fails) |
| `bash` | 7, 8, 37-58 (se scripts) | Fail |
| `sh` | 31, fake stubs | Fail |
| `zsh` | 20 | Fail |
| `awk` | 20, 68-70, helper | Fail |
| `grep` | 5, 7, 28, 51, 52, 68 | Fail |
| `readlink` | 19 | Fail |
| `fzf` | 36 | Hard fail (deliberately asserts, no skip) |
| `bun` | 64, 66 | Fail |
| `starship` / `zoxide` / `rgrc` | 72 / 73 / 74 | Skip with named message |
| `executor` (via `/Applications/Executor.app`) | 23 | Skip |
| `git` | (none in smoke; palette test uses it) | — |
| `mktemp`, `mkdir`, `chmod`, `cat`, `printf`, `env`, `tr`, `command` | many | coreutils, assumed present |
| `~/.local/bin/executor --version` | 23 | Skip-guarded by app bundle |
| bats-libs (bats-support/assert/file submodule) | all | common.bash errors at load: "bats-libs not found" |

---

## tests/palette.bats (57 tests)

### 1. Test names (exact, in file order)

1. `python3 is present and at least 3.9, the floor README.md declares`
2. `a missing python3 is rejected`
3. `a python3 below the floor, or one answering with junk, is rejected`
4. `palette sources under SOURCE_ROOT compile`
5. `Open in Zed resolves a nested repository directory and reuses the Zed window`
6. `Open in Zed falls back to a valid non-Git directory`
7. `Open in Zed rejects an empty directory before starting Zed`
8. `Open in Zed rejects a missing directory before starting Zed`
9. `Open in Zed resolves Zed from PATH and returns its exit status`
10. `Open in Zed rejects an invalid configured executable`
11. `Open in Zed reports its bounded timeout`
12. `Open in Zed uses the standard macOS CLI fallback`
13. `--validate accepts the real commands.toml and names the command count`
14. `--validate rejects an unsupported command type`
15. `load_commands reads a fixture config from the source tree`
16. `R1: lg ranks Lazygit in popup first`
17. `R1: ws ranks Switch workspace first`
18. `R1: edit ranks Edit command palette config first`
19. `R1: zed ranks Open in Zed first, and returns only it`
20. `R1: main ranks Merge main branch first`
21. `R1: lazy ranks Lazygit in popup first`
22. `R10: the Cyrillic shortcuts rank their command first`
23. `R1: the title tier is case-insensitive`
24. `R10: a half-typed shortcut still matches by prefix`
25. `R10: shortcut matching is case-insensitive`
26. `R10: a decoy title cannot displace a shortcut hit`
27. `R2: a query matching no title and no shortcut returns nothing`
28. `R2: an empty query returns every command in group order`
29. `a command with no shortcuts still matches by title`
30. `a title containing a tab does not corrupt the index mapping`
31. `--validate rejects a malformed shortcuts value`
32. `the fallback TOML parser reads a shortcuts array`
33. `select options rank through the same scorer`
34. `R3: every command is reachable at 40 commands in 8 groups`
35. `R3: the last drawn row never reaches the description line`
36. `R3: ten commands still render unscrolled`
37. `R3: a single group with no extra headers still scrolls`
38. `R4: pane_run refuses a pane an agent owns and says why`
39. `R4: pane_run proceeds when no agent owns the pane`
40. `R4: a failed pane lookup is reported, not treated as a free pane`
41. `R4: a herdr argv pane run is refused for an agent-owned pane too`
42. `R4: a herdr argv pane run proceeds when no agent owns the pane`
43. `R4: tab_run creates a tab and never consults the agent guard`
44. `R6: an open palette is found and focused instead of opening a second`
45. `R6: a pane that merely mentions palette.py is not the palette`
46. `R6: with no palette pane present, one is opened and marked`
47. `R6: overlay_shell clears the palette token before it execs`
48. `R6: the lookup costs one pane list and no process-info calls`
49. `R7: a bare {value} in a shell command is rejected, naming {value_q}`
50. `R7: {value_q} and {value_url} are accepted`
51. `R7: a bare {value} in a herdr argv array is accepted`
52. `R7: a bare {value} in a herdr argv array that runs a shell is rejected`
53. `R7: a bare {value} in a nested [run] table is rejected`
54. `R9: a missing fzf fails loudly, naming fzf, the Brewfile and PATH`
55. `R9: an fzf that fails leaves the palette alive and says so`
56. `R9: a config the validator rejects is reported, not raised`
57. `R9: an fzf that never answers leaves the palette alive and empty`

### 2. Bats mechanics per group

**File-level:** `load 'helpers/common'`; file-scope `PALETTE_DIR="$SOURCE_ROOT/private_dot_config/herdr/plugins/command-palette"` and `REAL_COMMANDS="$SOURCE_ROOT/private_dot_config/herdr/command-palette/commands.toml"`. Per-test `setup()`/`teardown()` (see section 3). Deliberate NO skip on missing python3 (comment in setup names docs/issues/2026-08-20-013). `PYTHONPATH` gains `tests/helpers` so heredoc python can `import palette_boot`.

Groups:

- **Tests 1-3 (python3 gate)**: test 1 calls `assert_python3_available` bare. Tests 2-3 mutate the real shell `PATH` variable in the test body (`PATH="$stub"` ... `run assert_python3_available` ... `PATH="$saved"`) — `run` of a *shell function*, not an executable; then `assert_failure` + `assert_output --partial`. Test 3 repeats the stub-write/PATH-swap cycle three times with different stub python3 scripts.
- **Test 4**: `run python3 -m py_compile <4 files>` + `assert_success` (depends on `PYTHONPYCACHEPREFIX` from setup for read-only source mounts).
- **Tests 5-12 (open_in_zed)**: create fake `zed` executables in `$PALETTE_WORK`; `run env ZED_BIN=... ZED_CALLS=... python3 "$OPEN_IN_ZED_PY" <dir>`; assertions include `assert_line --index 0 -- "-e"` (leading-dash arg guard), `assert_line --index 1 "$path"`, `assert_equal "$status" 7`, `assert_equal "$status" 124`, `[ ! -e "$calls" ]`, `run cat "$calls"`. Test 5 runs `git init -q`. Test 9 uses `env -u ZED_BIN PATH="$bin:$PATH"`. Tests 11-12 are heredoc `run env ... python3 - <<'PY'` monkeypatching module attributes (COMMAND_TIMEOUT_SECONDS=0.01; sys.platform/shutil.which). Test 11 sleeps 1s in the fake zed (wall-clock cost).
- **Tests 13-15, 31-33 (validate/load)**: `run python3 "$PALETTE_DIR/palette.py" --validate <file>` + `assert_success`/`assert_failure` + `assert_output --partial`; fixture TOML written into `$PALETTE_WORK`; test 31 loops over 4 bad `shortcuts` values re-running validate. Tests 15/32/33 are heredoc python via `palette_boot` (PYTHONPATH helper module). Test 32 blocks `tomllib` import inside python to force the fallback parser.
- **Tests 16-30 (ranking, R1/R2/R10)**: helper functions `rank_in()` / `rank_real()` — plain functions (no internal `run`), invoked as `run rank_real lg`; assertions `assert_line --index 0 "..."`, `assert_equal "${#lines[@]}" N` (relies on bats populating `$lines`), `assert_output ""`, `refute_output ""`, `assert_output --partial`. **These shell out to real `fzf`** through palette.py's scorer. Test 22 uses Cyrillic query strings (`дп`, `дфян`, `цы`, `яув`, `увше`) — UTF-8 handling must survive. Test 23 loops lower/upper pairs and compares two `run` outputs via saved `lower_out="$output"`. Test 26 appends a decoy to a copy of REAL_COMMANDS. Test 28 asserts exact command count of the real config (`assert_equal "${#lines[@]}" 10`) — brittle against config edits, but intentional.
- **Tests 34-37 (scrolling, R3)**: helper `scroll_fixture()` runs one python heredoc printing key/value lines; each test `run scroll_fixture` and asserts lines (`assert_line "visible 40"` etc.). Test 35 post-processes `$output` with awk into numeric compare.
- **Tests 38-43 (pane_run guard, R4)**: helper `stub_herdr()` writes a stub `herdr` bash script logging argv to `$dir/herdr.log` and answering canned JSON; `run_kind()`/`run_pane_run()` write a fixture commands.toml and run heredoc python with `HERDR_BIN_PATH`, `HERDR_TARGET_PANE_ID=w1:p1`, `HERDR_TARGET_CWD`, `HERDR_COMMAND_PALETTE_CONFIG` env. Assertions: `assert_line "code=0"` / `refute_line "code=0"` / `refute_line --partial "code=0"`, then `run cat <log>` + `assert_output --partial` / `refute_output --partial` on the argv log. Each test uses a distinct subdir of `$PALETTE_WORK` (agent/free/broken/argv-agent/argv-free/tabrun) — internally parallel-safe.
- **Tests 44-48 (opener, R6)**: helper `stub_opener_herdr()` (modes token/argv/none) + `run_opener()`; same log-file assertion pattern; test 48 uses `run grep -c '^pane list' <log>` + `assert_output "1"` and `run grep -c 'process-info'` + `assert_failure` (grep -c returning 0 matches exits 1). Test 47 reuses `stub_herdr` and heredoc python calling `palette.clear_palette_token`.
- **Tests 49-53 (form value quoting, R7)**: helper `validate_fixture()` reads fixture TOML from **stdin of the test** (`run validate_fixture <<'TOML'`) — a `run` whose command consumes the heredoc; `assert_failure`/`assert_success` + `assert_output --partial "{value_q}"`.
- **Tests 54-57 (fzf failure modes, R9)**: build stub `fzf` dirs. Test 54 runs under `env -i PATH="$stub:/usr/bin:/bin" HOME="$PALETTE_WORK"` — a scrubbed environment with symlinked python3/bash/sh/env in the stub dir (`ln -sf "$(command -v ...)"`); asserts the missing-fzf error names fzf, PATH, and both Brewfile paths. Tests 55/57 prepend broken/slow fzf stubs to PATH; test 57's stub `sleep 5` exercises the palette's own timeout (wall-clock cost; palette must time out faster than 5s). All assert `refute_output --partial "Traceback"`.

### 3. File-level setup/teardown (verbatim)

```bash
setup() {
  # No `command_exists python3 || skip` here. python3 is a declared requirement
  # (README.md, Requirements), so its absence must fail rather than silence all
  # 56 tests in this file from inside setup(). Deliberate exception to the skip
  # convention in docs/issues/2026-08-20-013-se-blocks-test-hard-fails-without-deps.md;
  # the first test below is what names the cause.
  export PALETTE_PY="$PALETTE_DIR/palette.py"
  export PALETTE_OPEN_PY="$PALETTE_DIR/open.py"
  export OPEN_IN_ZED_PY="$PALETTE_DIR/open_in_zed.py"
  export PYTHONPATH="$BATS_TEST_DIRNAME/helpers${PYTHONPATH:+:$PYTHONPATH}"
  PALETTE_WORK="$(mktemp -d "${BATS_TMPDIR:-/tmp}/palette.XXXXXX")"
  # Docker mounts the source tree read-only, so __pycache__ cannot live beside
  # the sources. py_compile reports that as a failure; redirect the cache.
  export PYTHONPYCACHEPREFIX="$PALETTE_WORK/pycache"
}

teardown() {
  [[ -n "${PALETTE_WORK:-}" ]] && rm -rf "$PALETTE_WORK" || true
}
```

No `setup_file`/`teardown_file`.

### 4. Migration hazards (palette.bats)

- **`run` of shell *functions*** (`run assert_python3_available`, `run rank_real`, `run scroll_fixture`, `run validate_fixture <<heredoc`, `run run_opener`, `run run_pane_run`): bats' `run` executes the function in the current shell context and captures output+status. A bashunit rewrite must capture `output=$(fn args 2>&1); status=$?` — and the heredoc-fed variant (`run validate_fixture <<'TOML'`) needs the heredoc redirected into the capture (`output=$(validate_fixture <<'TOML' ... )`).
- **In-shell PATH mutation across a `run`** (tests 2-3): `PATH="$stub"` then `run assert_python3_available` then `PATH="$saved"`. Under bashunit's shared-process model, an assertion failure between the swap and the restore would leave PATH broken for the *rest of the file's tests* (bats isolates per test; bashunit does not). Must be wrapped in a subshell or restore via trap/tear_down.
- **`$lines` semantics**: `assert_line --index N`, `assert_equal "${#lines[@]}" N`, `refute_line --partial`. Bats' `$lines` splits on newlines and *drops trailing empty output* handling differently than a naive `readarray`; test 27 asserts `assert_output ""` while test 19/22/30 assert exact line counts — the replacement splitter must reproduce bats behavior (empty output => 0 lines).
- **setup/teardown per test with `mktemp -d`**: maps to bashunit `set_up`/`tear_down`, but `teardown` runs even on failure in bats; ensure the bashunit equivalent also cleans on failure, and that `PALETTE_WORK` is per-test-unique for parallel runs (mktemp already guarantees this). `PYTHONPATH`/`PYTHONPYCACHEPREFIX` exports leak in a shared process — re-export per test or in set_up.
- **Real `fzf` dependency for ~15 ranking tests** (16-30, 33): tests shell through palette.py to real fzf. Parallel execution multiplies concurrent fzf/python3 processes (fine), but a missing fzf fails all ranking tests with confusing errors (only test 54's assertion explains it). Also **timing-sensitive tests**: 11 (sleep 1 fake zed + 0.01s timeout), 57 (sleep 5 stub fzf vs palette timeout) — under heavy parallel CPU load the palette's internal subprocess timeouts could get flaky; these two are the candidates for serialization or generous timeouts.
- **`env -i` scrubbed environment** (test 54): symlinks host `python3/bash/sh/env` into a stub dir and runs with `PATH="$stub:/usr/bin:/bin"`, `HOME="$PALETTE_WORK"`. Fragile against interpreters that need env vars (e.g. pyenv shims resolved via `command -v python3` at symlink time — the symlink pins the resolved binary, which is the intent). Behavior identical in bashunit, but note `command -v` runs in the *test* shell.
- **Exact-count assertions on the real config** (test 28: exactly 10 commands; test 13: `assert_output --partial "commands)"`): not a bashunit hazard per se, but any migration fixture snapshot must track `home/private_dot_config/herdr/command-palette/commands.toml`.
- **grep -c exit-status idiom** (test 48): `run grep -c 'process-info' log` + `assert_failure` — asserts zero matches via grep's exit 1. Keep as status check, not output check.
- **No inter-test ordering dependencies**: every test creates its own `$PALETTE_WORK` and subdirs. Parallel-safe given per-test set_up.

### 5. External commands invoked (palette.bats) and failure mode if absent

| Command | Tests | If absent |
|---|---|---|
| `python3` (>=3.9) | virtually all (1, 3-57) | Hard fail by design (test 1 names the cause; no skip) |
| `fzf` (real, >= palette floor) | 16-30, 33 (ranking through palette.py) | All ranking tests fail; test 54 is the one that *tests* absence via stub |
| `git` | 5 (`git init -q`) | Test 5 fails |
| `sh` | fake zed/notifier/fzf stubs (shebang `#!/bin/sh`) | Fail |
| `bash` | stub herdr scripts (`#!/usr/bin/env bash`) | Fail |
| `awk` | 35 | Fail |
| `grep` | 44-48 log assertions | Fail |
| `cat`, `chmod`, `mkdir`, `mktemp`, `printf`, `cp`, `ln`, `env`, `tr`, `sleep`, `touch`, `rm` | throughout | coreutils, assumed present |
| `tests/helpers/palette_boot.py` (via PYTHONPATH) | 15, 16-30, 32-33, 34-37, 38-43, 47, 55, 57 | Import error -> fail (not read for this inventory; referenced only) |
| bats-libs submodule | all | common.bash load error |

---

## Shared helper reference (tests/helpers/common.bash)

Loaded by both files. Key exports/functions consumed by these two suites:

- `CHEZMOI_BIN`, `PATH_WITHOUT_OP` (PATH stripped of dirs containing `op`), `CHEZMOI_SOURCE`, `SOURCE_ROOT` (resolved: checkout `../home` -> `$HOME/dotfiles` -> chezmoi source), `CHEZMOI_TEST_CONFIG=/tmp/chezmoi-test.yaml`.
- Loads bats-support, bats-assert, bats-file from `tests/helpers/bats-libs/` (submodule); `return 1` with error if missing.
- Sources `disposable-home.bash` (plain `source`, usable outside bats).
- Functions used by smoke/palette: `command_exists`, `assert_python3_available` (PYTHON3_MIN_VERSION="3.9"; relies on bats-support `fail` returning rather than aborting), `get_os`, `is_macos`, `is_linux`. (`skip_if_no_chezmoi`, `require_disposable_home`, `render_template`, `write_test_config`, `render_with_config`, `chezmoi_test_init` are not called by these two files.)
- Migration note: `assert_python3_available` calls bats-support `fail` — a bashunit port must supply a `fail` that records failure and returns 1 (the function's explicit `return 1` after each `fail` depends on that contract).
