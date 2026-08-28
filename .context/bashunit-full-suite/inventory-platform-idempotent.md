# Inventory: tests/platform.bats + tests/idempotent.bats (Bats → bashunit migration)

Sources read (worktree `/Users/seigiard/Projects/my-mac-setup/.claude/worktrees/optimize-test-suite-time`):
`tests/platform.bats`, `tests/idempotent.bats`, `tests/helpers/common.bash`,
`tests/helpers/disposable-home.bash`, `tests/run-post-apply.sh`, `Makefile`,
`docker/docker-compose.yml`, `docker/Dockerfile.ubuntu`, `.github/workflows/test-dotfiles.yml`.

## 1. Test names

### tests/platform.bats (2 tests)

1. `chezmoiignore filters macOS files on Linux`
2. `chezmoiignore includes macOS files on macOS`

### tests/idempotent.bats (13 tests)

1. `chezmoi apply is idempotent and leaves no pending diff`
2. `chezmoi verify succeeds`
3. `guard: MMS_DISPOSABLE_HOME=1 yields the run verdict`
4. `guard: no marker and no platform fact yields the skip verdict`
5. `guard: an empty marker does not yield run`
6. `guard: MMS_DISPOSABLE_HOME=0 does not yield run`
7. `guard: MMS_DISPOSABLE_HOME=true does not yield run`
8. `guard: an exported CI does not yield run`
9. `guard: GITHUB_ACTIONS without the marker yields misconfigured`
10. `guard: every disposable environment declares the marker`
11. `guard: the marker's claim covers chezmoi's real destination`
12. `guard: the skip message names make test-ubuntu and the marker`
13. `guard: the misconfigured message names the marker's write sites`

## 2. Per-test detail

### platform.bats

File preamble: `load 'helpers/common'`; a `setup()` that runs before every test:

```bash
setup() {
  skip_if_no_chezmoi
}
```

| Test | Bats features | Skip conditions (verbatim) | Behavior |
|---|---|---|---|
| `chezmoiignore filters macOS files on Linux` | `run`, `assert_success`, `refute_output --partial` ×6 | `setup`: `skip "chezmoi not installed"` (via `skip_if_no_chezmoi`); body: `is_linux \|\| skip "Only relevant on Linux"` | `PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" managed --source "$SOURCE_ROOT"`; asserts output does NOT contain `.hammerspoon`, `Library`, `.config/ghostty`, `.config/kitty`, `.config/karabiner`, `.config/zed`. Read-only; no temp dirs, no teardown, no filesystem effects. |
| `chezmoiignore includes macOS files on macOS` | `run`, `assert_success`, `assert_output --partial` ×5 | `setup` skip; body: `is_macos \|\| skip "Only relevant on macOS"` | Same command; asserts output DOES contain `.hammerspoon`, `.config/ghostty`, `.config/kitty`, `.config/karabiner`, `.config/zed` (note: no `Library` on the positive side). Read-only. |

Exactly one of the two runs per platform; the other skips. Env vars used: `PATH_WITHOUT_OP`, `CHEZMOI_BIN`, `SOURCE_ROOT` (all exported by common.bash). No serialization needs; safe under `--jobs`.

### idempotent.bats

File preamble: `load 'helpers/common'`; **`BATS_NO_PARALLELIZE_WITHIN_FILE=true`** at file scope (Bats-specific serialization directive), with this rationale comment: the two apply scenarios mutate the shared `$HOME` that every other test file reads deployed state from; concurrent applies would race, so the file stays sequential even when the suite runs with `--jobs`, and run-post-apply.sh keeps `--no-parallelize-across-files` in both modes. No `setup()`/`teardown()`/`setup_file()` in this file — deliberately: the guard is inline per test because a skip in `setup_file()` would take the `guard:` tests with it.

File-scope helper (plain bash function, defined between tests):

```bash
predicate_verdict() {
  env -u MMS_DISPOSABLE_HOME -u GITHUB_ACTIONS -u CI "$@" \
    bash -c '. "$1"; mms_disposable_home_verdict' _ \
    "$HELPERS_DIR/disposable-home.bash"
}
```

`env -u` scrubs the caller's environment so a developer with CI/marker exported cannot change what the guard tests measure. The plain `bash -c` is also the proof that `disposable-home.bash` needs no bats.

Per test:

1. **`chezmoi apply is idempotent and leaves no pending diff`** — first statement `require_disposable_home` (skip on workstation / hard-fail on marker-less runner / run when `MMS_DISPOSABLE_HOME=1`). Then three `run` invocations: `chezmoi apply --source="$CHEZMOI_SOURCE" --force --verbose` (`assert_success`), `chezmoi apply --source="$CHEZMOI_SOURCE" --force` (`assert_success`, `assert_output ""` — exact empty), `chezmoi diff --source="$CHEZMOI_SOURCE"` (`assert_success`, `assert_output ""`). **Filesystem effect: a real `chezmoi apply` onto `$HOME`**, including chezmoi run scripts (Homebrew install, brew bundle, on macOS `sudo defaults write`). Must be serialized against everything reading `$HOME`. No cleanup — the disposable-home contract IS the cleanup story.
2. **`chezmoi verify succeeds`** — `require_disposable_home`, then `run "$CHEZMOI_BIN" verify --source="$CHEZMOI_SOURCE"`, `assert_success`. Read-only, but guarded together with the apply so the file has one rule.
3. **`guard: MMS_DISPOSABLE_HOME=1 yields the run verdict`** — `run predicate_verdict MMS_DISPOSABLE_HOME=1`; `assert_success`; `assert_output "run"` (exact). No side effects.
4. **`guard: no marker and no platform fact yields the skip verdict`** — skip condition verbatim: `[[ ! -f /.dockerenv ]] || skip "/.dockerenv exists here"`. Then `run predicate_verdict`; `assert_success`; `assert_output "skip"`.
5. **`guard: an empty marker does not yield run`** — `run predicate_verdict MMS_DISPOSABLE_HOME=`; `assert_success`; `refute_output "run"` (exact-match negation).
6. **`guard: MMS_DISPOSABLE_HOME=0 does not yield run`** — same shape with `MMS_DISPOSABLE_HOME=0`.
7. **`guard: MMS_DISPOSABLE_HOME=true does not yield run`** — same shape with `MMS_DISPOSABLE_HOME=true`.
8. **`guard: an exported CI does not yield run`** — same shape with `CI=1`.
9. **`guard: GITHUB_ACTIONS without the marker yields misconfigured`** — `run predicate_verdict GITHUB_ACTIONS=true`; `assert_output "misconfigured"`.
10. **`guard: every disposable environment declares the marker`** — **never skipped** (comment: a skip would be indistinguishable from the file going inert). Branches: if `[[ -z "${GITHUB_ACTIONS:-}" ]] && [[ ! -f /.dockerenv ]]` — calls `mms_disposable_home_verdict` directly (no `run`) and `fail`s if it says `misconfigured`; otherwise asserts `[[ "${MMS_DISPOSABLE_HOME:-}" == "1" ]]` with a long `fail` message naming `.github/workflows/test-dotfiles.yml` and `docker/docker-compose.yml (services ubuntu, test-ubuntu, test-full)`. Uses bats-support `fail`.
11. **`guard: the marker's claim covers chezmoi's real destination`** — guards verbatim: `skip_if_no_chezmoi`; `[[ "${MMS_DISPOSABLE_HOME:-}" == "1" ]] || skip "marker unset, nothing claims this \$HOME is disposable"`; `assert_python3_available` (asserts, does not skip). Then reads `chezmoi dump-config --format=json`, extracts `destDir` via `python3 -c 'import json,sys; ...'`, and `assert_equal "$dest" "$HOME"`. Uses `local` vars, command substitution, bats-assert `assert_equal`.
12. **`guard: the skip message names make test-ubuntu and the marker`** — defines a nested function `captured_skip_message()` that **stubs** `mms_disposable_home_verdict() { echo "skip"; }` and `skip() { printf '%s' "$*"; }`, then calls `require_disposable_home`; `run captured_skip_message`; `assert_output --partial "make test-ubuntu"`; `assert_output --partial "MMS_DISPOSABLE_HOME"`. Relies on Bats `run` executing in a subshell so the stubs cannot leak into another test. (No status assertion — comment in the file preamble history: `run` swallows status here by design.)
13. **`guard: the misconfigured message names the marker's write sites`** — same stub pattern with `mms_disposable_home_verdict() { echo "misconfigured"; }` and `fail() { printf '%s' "$*"; return 0; }`; asserts output `--partial` `MMS_DISPOSABLE_HOME`, `test-dotfiles.yml`, `docker-compose.yml`.

Common facts for idempotent.bats:

- Env vars read: `MMS_DISPOSABLE_HOME`, `GITHUB_ACTIONS`, `CI`, `HOME`; plus `HELPERS_DIR`, `PATH_WITHOUT_OP`, `CHEZMOI_BIN`, `CHEZMOI_SOURCE` from common.bash.
- Temp dirs: none created by these two files.
- Cleanup: none; the apply tests intentionally leave `$HOME` mutated (disposable).
- Serialization: whole file must run sequentially and must not run concurrently with other files that read the deployed `$HOME` (which is all post-apply files) — hence `--no-parallelize-across-files` at the runner level and `BATS_NO_PARALLELIZE_WITHIN_FILE=true` at file level.

## 3. tests/helpers/common.bash — full function inventory

Top-level (runs at load time, not in a function):

```bash
HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "${HELPERS_DIR}/bats-libs/bats-support/load.bash" ]]; then
  echo "ERROR: bats-libs not found. Run: git submodule update --init --recursive" >&2
  return 1
fi

load "${HELPERS_DIR}/bats-libs/bats-support/load"
load "${HELPERS_DIR}/bats-libs/bats-assert/load"
load "${HELPERS_DIR}/bats-libs/bats-file/load"

source "${HELPERS_DIR}/disposable-home.bash"   # deliberately `source`, not `load`

CHEZMOI_BIN="$(command -v chezmoi 2>/dev/null || true)"
PATH_WITHOUT_OP=""
IFS=':' read -ra _path_dirs <<< "$PATH"
for _dir in "${_path_dirs[@]}"; do
  [[ -d "$_dir" ]] && [[ -x "$_dir/op" ]] && continue
  PATH_WITHOUT_OP="${PATH_WITHOUT_OP:+$PATH_WITHOUT_OP:}$_dir"
done
unset _path_dirs _dir
export CHEZMOI_BIN PATH_WITHOUT_OP

if command -v chezmoi >/dev/null 2>&1; then
  CHEZMOI_SOURCE="$(chezmoi source-path 2>/dev/null || echo "$HOME/.local/share/chezmoi")"
else
  CHEZMOI_SOURCE="${CHEZMOI_SOURCE:-$HOME/.local/share/chezmoi}"
fi
export CHEZMOI_SOURCE

SOURCE_ROOT="$(resolve_source_root)"
export SOURCE_ROOT

CHEZMOI_TEST_CONFIG="/tmp/chezmoi-test.yaml"
export CHEZMOI_TEST_CONFIG
```

Bats-specific dependencies in the top-level code:

- **`load`** (3 calls) — a Bats builtin; does not exist in plain bash or bashunit. The three bats libs (bats-support, bats-assert, bats-file) are what supply `assert_success`, `assert_output`, `refute_output`, `assert_equal`, `fail`. In bashunit these must be replaced by bashunit's own assertions (or the libs sourced manually — but they reference `BATS_*` internals, so replacement is the honest path).
- **`return 1` at file top level** — works because Bats `load`s this file; under plain `source` it also works, but the caller must check status.
- **`BASH_SOURCE[0]`** — plain bash, fine everywhere.
- The file is otherwise deliberately bats-light: `disposable-home.bash` is `source`d specifically so it works from plain `bash -c`.

Functions (full text):

```bash
resolve_source_root() {
  local root
  for root in \
    "${HELPERS_DIR}/../../home" \
    "$HOME/dotfiles" \
    "$CHEZMOI_SOURCE"; do
    if [[ -f "$root/.chezmoiignore" ]]; then
      (cd "$root" && pwd)
      return 0
    fi
  done
  echo "$CHEZMOI_SOURCE"
}
```
Pure bash. Order matters: host checkout `home/` wins (tests read uncommitted edits); Docker falls back to `$HOME/dotfiles` mount, then the chezmoi source copy.

```bash
chezmoi_test_init() {
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" init \
    --config "$CHEZMOI_TEST_CONFIG" \
    --config-path "$CHEZMOI_TEST_CONFIG" \
    "$@"
}
```
Pure bash. The mandated safe wrapper for `chezmoi init` outside Docker/CI (writes config to `/tmp/chezmoi-test.yaml` instead of the host's real config). Not used by platform/idempotent, but part of the shared helper contract other files rely on.

```bash
command_exists() {
  command -v "$1" >/dev/null 2>&1
}
```
Pure bash.

```bash
PYTHON3_MIN_VERSION="3.9"

assert_python3_available() {
  local readme="the Requirements section of README.md"
  local bin found major minor min_major min_minor

  if ! command_exists python3; then
    fail "python3 is not on PATH. It is the herdr command palette's interpreter and a declared requirement of this repository -- see $readme. Every supported OS ships one, so this repository does not install it."
    return 1
  fi

  bin="$(command -v python3)"
  found="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)" || found=""
  if [[ ! "$found" =~ ^[0-9]+\.[0-9]+$ ]]; then
    fail "python3 at $bin answered the version probe with '$found' instead of a major.minor number, so it cannot be checked against the $PYTHON3_MIN_VERSION floor stated in $readme. A wrapper or stub shadowing the real interpreter on PATH looks like this."
    return 1
  fi

  major="${found%%.*}"
  minor="${found#*.}"
  min_major="${PYTHON3_MIN_VERSION%%.*}"
  min_minor="${PYTHON3_MIN_VERSION#*.}"
  if (( 10#$major < 10#$min_major || (10#$major == 10#$min_major && 10#$minor < 10#$min_minor) )); then
    fail "python3 at $bin is $found, older than the $PYTHON3_MIN_VERSION this repository requires -- see $readme. The palette's sources are kept compiling on $PYTHON3_MIN_VERSION because that is what macOS ships at /usr/bin/python3."
    return 1
  fi
}
```
Depends on **bats-support's `fail`** (prints to the fail stream, returns 1, does NOT abort the function — which is why every branch `return`s explicitly). bashunit has `bashunit::fail <?message>` with fail-the-test semantics; the explicit `return 1` after each call must be preserved. Note idempotent.bats test 13 **stubs `fail`** by redefining it — a migration must keep `fail` an overridable shell function, not a hardcoded internal.

```bash
get_os() {
  case "$(uname -s)" in
    Darwin) echo "darwin" ;;
    Linux)  echo "linux" ;;
    *)      echo "unknown" ;;
  esac
}

is_macos() {
  [[ "$(get_os)" == "darwin" ]]
}

is_linux() {
  [[ "$(get_os)" == "linux" ]]
}
```
Pure bash.

```bash
skip_if_no_chezmoi() {
  if ! command_exists chezmoi; then
    skip "chezmoi not installed"
  fi
}
```
Depends on **Bats `skip`**: in Bats, `skip` inside `setup()` or a test ends the test immediately with skipped status. bashunit's `bashunit::skip` does NOT stop the test (needs `&& return` at the call site, which does not propagate up through a helper function); the conditional helpers `bashunit::skip_if` / `bashunit::skip_unless_command` DO stop the test — but only when called from the test body, not from inside `$(...)` subshells. This helper's semantics change under bashunit and must be rethought (e.g. `bashunit::skip_unless_command chezmoi` inline in each test, or `set_up() { ... }` behavior verified explicitly).

```bash
require_disposable_home() {
  case "$(mms_disposable_home_verdict)" in
    run)
      return 0
      ;;
    misconfigured)
      fail "MMS_DISPOSABLE_HOME is not 1, but this environment reports a disposable \$HOME (GITHUB_ACTIONS is set, or /.dockerenv exists). Declare the marker at the site that launched this suite, or these tests lose their coverage silently: .github/workflows/test-dotfiles.yml (top-level env: block), and docker/docker-compose.yml (services ubuntu, test-ubuntu, test-full)."
      return 1
      ;;
    *)
      skip "would run a real chezmoi apply against this \$HOME, not a sandbox, so on a workstation it overwrites your live dotfiles and runs the install scripts -- use 'make test-ubuntu' for this coverage, or set MMS_DISPOSABLE_HOME=1 to declare this \$HOME disposable (that opt-in applies --source=\$CHEZMOI_SOURCE, the separate chezmoi clone, not this checkout)"
      ;;
  esac
}
```
Depends on Bats `skip` (must abort the calling test from inside a helper) and `fail`. **This is the safety-critical function**: if `skip` fails open under bashunit (marks skipped but keeps executing, or does nothing when called from a nested function), the very next lines of the apply test run a real `chezmoi apply` on a workstation `$HOME`. Both `skip` and `fail` are also stubbed by tests 12–13, so they must remain plain overridable functions.

```bash
render_template() {
  local template_file="$1"
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" execute-template < "$template_file"
}

write_test_config() {
  local out="$1"
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" execute-template --init \
    --source "$SOURCE_ROOT" < "$SOURCE_ROOT/.chezmoi.yaml.tmpl" > "$out"
}

render_with_config() {
  local config_file="$1"
  local template_file="$2"
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" \
    --config "$config_file" --source "$SOURCE_ROOT" \
    execute-template < "$template_file"
}
```
Pure bash; used by other suite files (templates/smoke), not by platform/idempotent.

`tests/helpers/disposable-home.bash` (sourced, dependency-free by design):

```bash
mms_disposable_home_verdict() {
  if [[ "${MMS_DISPOSABLE_HOME:-}" == "1" ]]; then
    echo "run"
    return 0
  fi
  if [[ -n "${GITHUB_ACTIONS:-}" ]] || [[ -f /.dockerenv ]]; then
    echo "misconfigured"
    return 0
  fi
  echo "skip"
}
```
Truth table: exact-match `"1"` → `run`; `GITHUB_ACTIONS` set or `/.dockerenv` exists (without marker) → `misconfigured`; otherwise → `skip`. Guard fails closed (`0`, `true`, empty all refuse `run`). No bats/BATS_* dependencies — must stay that way; idempotent test 4's comment says the plain `bash -c` IS the proof.

No `BATS_TEST_TMPDIR` / `BATS_*` variables are used anywhere in these files except the file-scope `BATS_NO_PARALLELIZE_WITHIN_FILE=true` directive in idempotent.bats.

## 4. Production invocation

### tests/run-post-apply.sh

Two modes; both end in the same exec line:

- `full` → `tests/smoke.bats tests/scripts.bats tests/palette.bats tests/platform.bats tests/idempotent.bats`
- `host-safe` → same list **minus** `tests/idempotent.bats`
- Anything else → usage on stderr, `exit 2`.
- Final: `exec bats --jobs 8 --no-parallelize-across-files "$@"` — 8-way parallelism **within** each file, files strictly sequential. idempotent.bats additionally serializes within itself via `BATS_NO_PARALLELIZE_WITHIN_FILE=true`.

### Makefile

- `test-suite` (host): prints two NOTE blocks (idempotent excluded; asserts already-applied `~/`, not the checkout), then `tests/run-post-apply.sh host-safe`. Depends on `init-submodules` (bats-libs submodule check + `git submodule update --init --recursive`).
- `test-ubuntu`: `test-issues build-docker` then `docker compose -f docker/docker-compose.yml run --rm test-ubuntu`.
- `test-docker`: same but service `test-full`.
- `test-templates`: runs only `bats tests/templates.bats` inside the `test-ubuntu` service with an inline command.

### Docker (docker/docker-compose.yml)

All three services (`ubuntu`, `test-full`, `test-ubuntu`) mount `../home` → `/home/testuser/dotfiles:ro`, `../tests` → `/home/testuser/tests:ro`, and set env: `CHEZMOI_NAME="Test User"`, `CHEZMOI_EMAIL=test@example.com`, `HOMEBREW_NO_AUTO_UPDATE=1`, `HOMEBREW_NO_INSTALL_CLEANUP=1`, **`MMS_DISPOSABLE_HOME=1` written literally** (idempotent.bats hard-fails when `/.dockerenv` exists and it is missing). `test-full` also passes `MMS_CI_MINIMAL=${MMS_CI_MINIMAL:-}`; `test-ubuntu` deliberately does not.

`test-ubuntu` / `test-full` entrypoint (`/bin/bash -c`) sequence: stage a writable worktree under `/home/testuser/worktree` (copies dotfiles, tests, issues CLI, Makefile, README; fake `.git`), copy `home/` into `/home/testuser/.local/share/chezmoi/`, `chezmoi init --source=/home/testuser/.local/share/chezmoi --promptString name="Test User" --promptString email="test@example.com"`, `bats tests/templates.bats` (pre-apply gate), `chezmoi apply --source=... --verbose`, `make test-smithers`, then **`tests/run-post-apply.sh full`**.

`docker/Dockerfile.ubuntu`: ubuntu:24.04, installs bats via `brew install bats-core` (also chezmoi, fzf, bun via Linuxbrew), creates `testuser` with passwordless sudo.

### CI (.github/workflows/test-dotfiles.yml)

Top-level env (both jobs): `CHEZMOI_NAME`, `CHEZMOI_EMAIL`, `MMS_CI_MINIMAL` (trigger-conditional), **`MMS_DISPOSABLE_HOME: "1"` unconditional**, `MISE_NODE_VERIFY: "false"`, `HOMEBREW_NO_INSTALL_CLEANUP: "1"`, `HOMEBREW_NO_AUTO_UPDATE: "1"`.

- `test-ubuntu` job: installs bats via `sudo apt-get install -y bats`; after apply + smithers gate, an **"Assert the parallel-run prerequisites"** step: `command -v flock || command -v shlock`, then asserts `bats --version` ≥ 1.5; then `tests/run-post-apply.sh full`.
- `test-macos` job: installs bats via `brew install bats-core`; adds `scripts/ci/macos-bats-flock-bin` to `GITHUB_PATH` (**a repo-local flock wrapper mapping Bats' simple lock form to `lockf`**, because bats-core's shlock backend polls with a 1-second sleep under contention); asserts the wrapper is the resolved `flock`, `command -v lockf`, bats ≥ 1.5; then `tests/run-post-apply.sh full`.
- Both jobs run `bats tests/templates.bats` earlier as the pre-apply gate (outside run-post-apply.sh).

## 5. Migration hazards

1. **Skip-from-helper semantics (safety-critical).** Bats `skip` aborts the current test from any depth, including from `setup()` and nested helpers (`skip_if_no_chezmoi`, `require_disposable_home`). bashunit's `bashunit::skip` only *marks* and relies on `&& return` at the immediate call site — a `return` inside a helper returns from the *helper*, not the test. If `require_disposable_home` cannot abort the test, the workstation-protection guard fails open and the next statement is a real `chezmoi apply` over the developer's `$HOME`. The conditional helpers (`bashunit::skip_if` etc.) do stop the test, but their behavior when wrapped in another function must be proven, not assumed. This one hazard alone justifies a red/green harness test before trusting the port.
2. **`fail`/`skip` stubbing and message tests.** Tests 12–13 stub `skip`, `fail`, and `mms_disposable_home_verdict` inside a `run` subshell to capture guard messages. bashunit's `assert_exec` runs a *string* command, not a locally-defined function with local stubs, and bashunit's own `bashunit::fail` is namespaced. The stub-based message tests need restructuring (e.g. run the helper through `bash -c` with sourced files, mirroring `predicate_verdict`), and `fail` must remain an overridable function.
3. **Serialization contract.** Today's contract is `--jobs 8 --no-parallelize-across-files` + `BATS_NO_PARALLELIZE_WITHIN_FILE=true` in idempotent.bats: parallel *within* host-safe files, files sequential, idempotent fully sequential. bashunit inverts the granularity: `--parallel` runs files AND tests concurrently, and its per-file opt-out (`# bashunit: no-parallel-tests` as line 2) only serializes tests *within* the file while the file still runs concurrently with others — exactly what the apply tests must not do (every other file reads the `$HOME` the apply mutates). A faithful port likely needs idempotent run as a separate sequential invocation, or the whole suite's parallel model redesigned.
4. **bats-assert surface → bashunit assertions.** `run` + `$status/$output`, `assert_output ""` (exact-empty), `assert_output --partial`, `refute_output` (exact-match negation) and `refute_output --partial` have no 1:1 equivalents; the closest is `assert_exec "cmd" --exit 0 --stdout "" --stdout-contains/--stdout-not-contains`. Two traps: `assert_exec` takes the command as a string (re-quoting `PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" managed --source "$SOURCE_ROOT"` with spaces in paths), and bashunit 0.50.1 **silently drops unrecognised `assert_exec` flags** — a typo like `--stdout-contain` passes on exit status alone. Also `refute_output "run"` is *exact-match* negation ("output is not exactly `run`"), not substring — `--stdout-not-contains "run"` would be a stricter, different assertion.
5. **`load` and load-time side effects.** common.bash `load`s three bats libs and executes environment setup (`PATH_WITHOUT_OP` computation, `CHEZMOI_SOURCE`, `SOURCE_ROOT`) at load time. Under bashunit this becomes a `source` from `tests/bootstrap.sh` or `set_up_before_script`; the bats-libs `load` lines must be removed/guarded, and every other `.bats` file still `load`ing common.bash constrains a partial migration — the helper must serve both frameworks or fork.
6. **Guard hard-fail vs. bashunit exit-0-on-skip.** The design leans on "bats exits 0 on skip" being compensated by `fail` in the misconfigured path. bashunit also exits 0 on skipped/incomplete/risky; the `guard:` tests' fail paths must genuinely fail the run, and the "risky" status (test that asserted nothing) is a new silent-green mode Bats did not have — e.g. a mis-ported skip helper could leave a test asserting nothing and reported risky yet exit 0 (mitigate with `--fail-on-risky`).
7. **Invocation surface spread across four call sites.** `tests/run-post-apply.sh` (both modes), the two docker-compose service commands, the CI parallel-prerequisites steps (flock/shlock assertion + the macOS `scripts/ci/macos-bats-flock-bin` wrapper — both Bats-specific and deletable only when Bats fully leaves), Dockerfile's `brew install bats-core`, CI's `apt-get install bats` / `brew install bats-core`, and `make init-submodules`' bats-libs submodule check all encode Bats. A migration that misses one site runs zero tests somewhere while looking green (note `run-post-apply.sh` `exec`s — exit code propagation must be preserved; bashunit exits non-zero on empty selection by default, which is a useful guard here).
8. **Name-derived reporting and filtering.** Bats test names are free strings (`guard: ...` with spaces and colons); bashunit tests are functions, names `test_`-prefixed identifiers. The documented workflow `bats --filter 'guard:' tests/idempotent.bats` becomes `--filter` on function names; `bashunit::set_test_title` can preserve display names but not filter behavior. Anything grepping test output for the old names (docs, issues) drifts.
