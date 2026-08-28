# bashunit 0.50.1 — capability research

Sources: docs at tag `0.50.1` of github.com/TypedDevs/bashunit (`docs/*.md`, fetched raw — the live site bashunit.com tracks main, so everything below was verified against the tagged docs), release list via `gh api` (tag `0.50.1` confirmed to exist; it is the latest release as of 2026-08-28).

## Test definition

- Discovery: a path argument; for a directory, all files ending `test.sh` or `test.bash` recursively. Wildcards work but a `*test.sh` pattern is recommended for scan speed.
- A test is any function whose name starts with the literal lowercase `test_` (underscore included). `testFoo`, `TEST_x` are silently treated as auxiliary functions — no warning; verify with `--list`.
- All three bash function syntaxes work (`function name()`, `name()`, `function name`).
- Display name is derived (humanized) from the function name; `bashunit::set_test_title "..."` overrides display only (reset after each test).
- Per-test comment annotations directly above the function: `# @tag <name>`, `# @timeout <s>`, `# @retry <n>`, `# @skip [reason]` (body and hooks never run). A blank line breaks the annotation block.

## Assertions

100+ assertions, global names (no namespace). Relevant subset:

- Equality/strings: `assert_same` (exact), `assert_equals` (normalizes/ignores color codes), `assert_not_same`, `assert_not_equals`, `assert_contains`, `assert_not_contains`, `assert_contains_ignore_case`, `assert_matches` / `assert_not_matches` (regex), `assert_string_starts_with` / `_ends_with` (+ negations), `assert_empty`, `assert_not_empty`, `assert_line_count`.
- Exit codes: `assert_exit_code <code> ["command"]` — with no command it checks `$?` of the previous command; `assert_successful_code`, `assert_unsuccessful_code`, `assert_general_error`, `assert_command_available`, `assert_command_not_found`.
- Files/dirs: `assert_file_exists`, `assert_file_contains`, `assert_is_file*`, `assert_file_permissions`, `assert_symlink_to`, `assert_directory_exists`, `assert_is_directory*`, `assert_files_equals`, plus negations.
- Numbers, dates, arrays (`assert_arrays_equal`, `assert_array_contains`, `assert_array_length`), JSON (`assert_json_equals`, `assert_json_contains`, `assert_json_key_exists`, `assert_json_length`), duration, snapshots (`assert_match_snapshot`), spies (`assert_have_been_called`, `..._with`, `..._times`, `assert_not_called`).
- Meta: `assert_assertion_passes` / `assert_assertion_fails[_with]`; manual failure `bashunit::fail <?message>`.
- Custom-assertion plumbing: `bashunit::assert_that`, `bashunit::assert_once`, `bashunit::assertion_passed`, `bashunit::assertion_failed`.

### Equivalent of Bats `run` (status+stdout+stderr capture)

`assert_exec` is the closest analogue, but it is assert-and-capture in one call rather than capture-then-assert:

```
assert_exec "command" [--exit <code>] [--stdout "text"] [--stderr "text"]
            [--stdout-contains "s"] [--stdout-not-contains "s"]
            [--stderr-contains "s"] [--stderr-not-contains "s"] [--stdin "input"]
```

- Runs `command` (a *string*, re-evaluated — quoting of embedded paths/env-prefixes is on you), captures exit status, stdout, stderr; checks all provided expectations. `--exit` omitted defaults to expected `0`.
- **Caveat (verbatim from 0.50.1 docs): unrecognised arguments are silently dropped** — a mistyped `--stdout-contain` checks nothing and the assertion passes on exit status alone.
- There is no built-in that just populates `$status`/`$output` variables. The manual pattern is plain bash: `output="$(cmd 2>&1)"; code=$?` then `assert_same`/`assert_contains` on the captured variables (works because assertions can be called anywhere in the test body, multiple times).

## Lifecycle hooks (exact names, 0.50.1)

| Hook | Runs |
|---|---|
| `set_up` | before each test function in the file |
| `tear_down` | immediately after each test function |
| `set_up_before_script` | once before all tests in the file; shown in output with duration |
| `tear_down_after_script` | once after the file finishes; also runs when `set_up_before_script` failed |

- A failing `set_up_before_script` marks **every test in the file failed** (counted in totals), reports the hook error, and continues with the next file. Watch a trailing `cmd && var=value` — the guard becomes the hook's return value. To turn a missing optional dependency into skips instead, end the hook `...; return 0` and skip inside tests.
- `tear_down_after_script` failures surface as dedicated errors after the summary.
- Shared cross-file setup: `tests/bootstrap.sh` (sourced before tests; path configurable via `BASHUNIT_BOOTSTRAP` / `-e|--env`; can receive arguments). Note: functions defined via bootstrap must be `export -f`'d to reach test subshells per the configuration doc; **shell aliases are NOT available in tests due to bashunit's subshell architecture** — each test function executes in an isolated subshell (`runner::run_test` runs tests in child processes), so env mutations in one test do not leak into the next.

## Skip / todo

- `bashunit::skip "[reason]"` — marks the test skipped but does **not** stop execution; canonical usage is `bashunit::skip "reason" && return` in the test body. Reported as `↷ Skipped: <name>` with the reason indented; counted (`N skipped`) and "Some tests skipped" in the summary; **does not** make the exit code non-zero.
- Conditional helpers that mark **and end** the test (no `&& return` — adding one is a documented bug that yields a "risky" no-assertion test): `bashunit::skip_if <condition> "[reason]"`, `bashunit::skip_unless <condition> "[reason]"`, `bashunit::skip_unless_command <cmd> [cmd...]` (reports `requires <cmd>`), `bashunit::skip_on <windows|macos|linux> "[reason]"`. Called from inside a `$(...)` subshell they end only that subshell — call from the test body.
- Declarative: `# @skip [reason]` annotation above the function — body and hooks never run.
- `bashunit::todo "[pending]"` — marks incomplete (`✒ Incomplete`); exit code unaffected.
- Skipped/incomplete/risky runs all exit 0; `--fail-on-risky` / `--fail-on-flaky` tighten this. There is no bats-style skip-from-`set_up` documented; skip is a per-test-body affair.

## Parallel execution

- Flag: `-p|--parallel` (opposite: `--no-parallel`; sequential is the default). `-j|--jobs <N|auto>` caps workers and implicitly enables parallel (`0` = unlimited = same as `--parallel`; `auto` = CPU cores).
- Granularity: **both test files and individual test functions run concurrently.** Per-file opt-out of *test-level* parallelism: `# bashunit: no-parallel-tests` as the **second line** of the file — the file still runs in parallel with other files, only its tests serialize. **There is no documented way to make one file exclusive against all other files** (no bats `--no-parallelize-across-files` equivalent) short of `--no-parallel` for the whole run or invoking that file separately.
- Platform support (0.50.1 docs, verbatim): "Parallel mode is supported on **macOS**, **Ubuntu**, **Alpine**, and **Windows**." Automatically disabled on incompatible systems. So yes — parallel works on macOS in 0.50.1, with no flock/shlock prerequisite (unlike bats).
- Result merging is internal (workers write under a bashunit temp area, e.g. `/tmp/bashunit/parallel`, cleaned after the run; aggregation is transparent). Under `--parallel`, per-test row order in json/tap output follows completion order, not definition order. Coverage, retry counters, `--repeat`, snapshot cache, and `--random` seeds are documented as parallel-safe; `--stop-on-failure` composes with `--parallel`.

## Output, exit codes, filtering, listing

- `--output <text|tap|json|junit>` on stdout (tap = TAP version 13 with `1..N` plan, `ok/not ok` lines, YAML failure blocks; non-text formats suppress header/progress, diagnostics go to stderr). File reporters, combinable with `--output`: `--report-json`, `--report-junit`, `--report-html`, `--report-md` (auto-appends to `$GITHUB_STEP_SUMMARY` in Actions), `--report-tap`. `-s|--simple` compact console style. GitHub Actions error annotations are automatic on runners.
- Exit codes: `0` = nothing failed — **entirely skipped/incomplete/risky runs also exit 0**; failures (including a syntax error in a test file, which is recorded as a failing "Source" test) exit non-zero. **Selecting zero tests exits non-zero** unless `--pass-with-no-tests`; a nonexistent path is always refused. `--fail-on-risky`, `--fail-on-flaky` available.
- Filtering: `-f|--filter <name>` (case-sensitive match on function names), `--exclude-filter`, inline `path::function_name` and `path:line`, `--tag`/`--exclude-tag` with AND/NOT expressions, `--shard <index/total>`, `--changed [ref]`, named suites via `.bashunitrc` (`--suite <name>`, `--list-suites`).
- Listing: `--list` / `--dry-run` prints selected tests as `path::function` (count to stderr; honors all filters; empty selection prints nothing, exits 0); `--list --list-format json` adds file/function/humanized name/line/tags; `--list-tags`.
- Misc run controls: `--test-timeout <s>` (bash 3.0+ incl. macOS default bash — no `timeout` command needed), `--retry <n>`, `--random [seed]`, `--repeat <n>`, `--stop-on-failure`, `--sandbox [--sandbox-allow <cmds>]` (fail any unmocked external command), `--profile`, `--verbose`/`--show-output-on-failure`, `bench`/`watch`/`assert`/`doc` subcommands.

## Temp dirs and env isolation

- `bashunit::temp_file <?prefix>` and `bashunit::temp_dir <?prefix>` — created files/dirs are **automatically deleted when bashunit completes** (also cleaned when created in `set_up_before_script`; spy temp files are isolated per test run so parallel runs don't clash).
- Other globals: `bashunit::current_dir`, `bashunit::current_filename`, `bashunit::caller_filename`, `bashunit::caller_line`, `bashunit::current_timestamp`, `bashunit::random_str <?length>`, `bashunit::is_command_available <cmd>`, `bashunit::print_line`, `bashunit::log` (to `BASHUNIT_DEV_LOG`).
- Env isolation: each test function runs in its own subshell/child process (the docs call it "bashunit's subshell architecture"); tests cannot leak variables into each other; bootstrap-defined functions need `export -f`; aliases don't survive into tests.
- Configuration: `BASHUNIT_*` env vars, `.env` (default; `-e|--env <file>` overrides), `.bashunitrc` (global + `[suite:<name>]` sections). Precedence: CLI flags → suite settings → `.bashunitrc` → `.env` → defaults.

## Pinned installation (0.50.1, repo-local single file)

```bash
curl -s https://bashunit.com/install.sh | bash -s lib 0.50.1
# → ./lib/bashunit  (single-file executable; args: [dir] [version], defaults lib / latest)
```

- `install.sh` auto-verifies the download against the release `checksum` asset and aborts on mismatch. `BASHUNIT_VERIFY_CHECKSUM=true` also aborts when verification is *impossible* (default only warns); `false` skips. Per-version checksum published at `https://github.com/TypedDevs/bashunit/releases/download/0.50.1/checksum`; the docs' pinned SHA256 for the current release file: `18d83d590c5304f1853dd4fe4fec4ec6effbd9fe5a21831fe9f66f70afe17d93` — re-verify against the release asset when vendoring, e.g. `shasum -a 256 lib/bashunit`.
- Since it is one committed file, the most reproducible route is: install once, verify checksum, commit `lib/bashunit` (or `tests/lib/bashunit`) to the repo — no submodule, no per-CI install step, identical binary on macOS and Ubuntu. Alternatives: `npm i --save-dev bashunit` (prebuilt single file only; no sourcing internals), brew/MacPorts/Nix (unpinned/lagging — docs point to install.sh for a specific version).

## Bash version requirement (critical)

- **0.50.1 installation doc, verbatim: "bashunit requires Bash 3.0 or newer."** The doc's own description line: "a single-file bash testing framework running on Bash 3.0+ (Linux, macOS, WSL)."
- **macOS default `/bin/bash` 3.2 is therefore supported**, and features are explicitly kept 3.0-compatible (e.g. `--test-timeout` "works on Bash 3.0+ (including the default macOS Bash)"). Parallel mode explicitly supports macOS.
- No known 3.2 incompatibilities are documented for 0.50.1. Practical cautions: (a) *your test files* must also stay bash-3.2-clean when run under `/bin/bash` — no `declare -A`, no `${var,,}`, no `readarray`; (b) on macOS the shebang/interpreter that runs `lib/bashunit` decides which bash executes the suite — if Homebrew bash 5 is on PATH (`#!/usr/bin/env bash`), tests run under bash 5 on dev machines but would run under 3.2 on a bare mac; pin the interpreter explicitly if that difference matters. Windows/Git Bash is the platform the docs flag as problematic (for npm installs), not macOS.

## Deltas vs. the live site (main) worth knowing

Everything above was checked against the `0.50.1` tag, and 0.50.1 is currently the newest release, so the live bashunit.com docs match it today. The old domain bashunit.typeddevs.com 301-redirects to bashunit.com.
