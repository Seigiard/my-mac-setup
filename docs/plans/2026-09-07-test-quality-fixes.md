# Test quality fixes

Source: six-agent audit of `tests/bashunit/` (2026-09-07) using two review skills
(analyzing-test-effectiveness, testing-skill) with cross-checked partitions. This plan
carries every accepted finding. Each item is one commit; the repository works after each.

Verification baseline for every item: `make lint` and the touched suite via
`tests/lib/bashunit -j 8 tests/bashunit/<file>_test.sh`. Items touching templates or
deployment behavior additionally note their own checks.

## Items

### P1 · Stall-proof `chezmoi_unattended_test.sh` test 009

Observed once live: the fake chezmoi's signal mode loops `while :; do sleep 1; done`
unbounded, and the test has no failure-path cleanup, so a failed assertion between
launch and `kill` hangs the whole suite (documented class:
`docs/solutions/design-patterns/outliving-processes-hang-the-suite.md`).
Fix: cap the fake's wait loop (exit 143 after a bounded number of iterations), kill the
backgrounded launcher from `tear_down`/trap, and replace the fixed ~1s pid-file poll
with a state-aware longer bound (latent-flake class:
`docs/solutions/.../idle-machine-wall-clock-bounds-are-latent-flakes.md`).

Oracle: consumer = suite runner; observable failure = suite hangs indefinitely after an
assertion failure inside test 009; oracle = existing test 009 assertions still pass and
a bounded run terminates — no new test, only fixture hardening.

Done when: full `chezmoi_unattended_test.sh` passes twice in a row within its runtime
budget; the fake's loop has a hard bound; teardown kills the launcher.

### P2 · Launcher guard and failure-propagation coverage

`tests/helpers/chezmoi-unattended` fail-closed branches with zero coverage:
unknown option before `--` (:44), missing `--` delimiter (:49), empty command after
`--` (:54), the exactly-five-fixture-identities inventory rule (:141-142),
single-target-too-long (:236-237). Plus: test 0071 (:282-306) asserts only failure with
no message fragment — add `assert_output --partial` on the launcher's non-terminal-stdin
message. Plus: extend the fake chezmoi so `managed` can fail and a mid-batch diff can
fail, then assert the launcher exits with the child's status (:215-217, :238-242).

Oracle: consumer = CI invoking the launcher; observable failure = a guard silently
passes a malformed invocation through to a real `chezmoi apply`, or a failing batch
diff reads as green; oracle = filesystem markers written by the fake
(`assert_final_not_reached`) plus the launcher's exit status and stderr message —
independent of this patch's edits to the test file.

Done when: each listed branch has a rejection test with a message fragment and a nearby
valid control; failure-propagation tests pass; suite green.

### P3 · Behavior tests for `smart_close.py`

The only coverage today is `py_compile`. Cover the three decision branches (close pane
when tab has >1 panes; else close tab when workspace has >1 tabs; else refuse + notify)
and the error-notify path, using the existing `stub_herdr` pattern
(`palette_test.sh:784-807`).

Oracle: consumer = herdr keybinding invoking `smart_close.py` on Cmd-W; observable
failure = the last tab of a workspace gets closed (data loss) or close requests go to
the wrong object; oracle = argv recorded by the stubbed `herdr` binary — the stub log
is independent of `smart_close.py`'s source.

Done when: four behavioral tests pass; a hand-inverted branch (mutation check during
development, not committed) flips at least one test red.

### P4 · Palette ranking block onto fixtures

Tests 016-025 pin titles/shortcuts copied from mutable production `commands.toml`
(same-patch-oracle hazard the file itself documents at `palette_test.sh:487-493`).
Replace with: fixture-backed mechanism tests (pattern of 026/029/030) for shortcut-tier
vs title-tier, prefix match, case folding; one self-maintaining inventory test that
reads every `shortcuts` declaration from the deployed `commands.toml` and asserts each
ranks its own command first; one new fixture pinning exact-shortcut-beats-prefix-shortcut
(`palette.py:620-645`). Drop the count-of-1 assertions at :389 and :412. Also:
consolidate scroll tests 034-037 into one test with four assertions (one subprocess
run), and fix the stale "58 tests" comment at :25.

Oracle: consumer = palette user typing a query; observable failure = a shortcut stops
ranking its command first; oracle = ranking output over test-owned fixtures (mechanism)
and the config-derived relationship "each declared shortcut ranks its own command
first" (two independent sides: config declaration vs ranker output).

Done when: mechanism tests run on fixtures only; inventory test derives expectations
from `commands.toml` at runtime; suite green.

### P5 · Untested palette run paths

Cover: `plugin_action` kind (`palette.py:1947-1956`), plain `shell` kind including the
runtime `append_value` quoting (`palette.py:1962-1963` — inject a hostile value, assert
inertness like the existing `PWNED` marker test at :1431-1478), and `pane_run` with
`HERDR_TARGET_PANE_ID` unset (`palette.py:1888-1890`).

Oracle: consumer = palette executing a selected command; observable failure = injected
shell metacharacters execute, or a run path crashes/targets the wrong pane; oracle =
stub argv logs and a marker file that must NOT exist after a hostile append value.

Done when: three run paths have behavioral tests; hostile-value test uses a
would-be-created marker as its negative oracle; suite green.

### P6 · morning-cleanup destructive legs

`home/dot_local/bin/executable_morning-cleanup.sh` trash purge (`rm -rf` by ctime,
:28-33) and platform worktree/branch cleanup (`git worktree remove`, `git branch -d` of
merged branches, :51-76) have zero tests. Add an age-threshold env knob to the script
(shipped default stays the control), then: a stale entry the purge must remove, a fresh
entry it must keep; a git fixture (bare origin, merged-clean worktree, unmerged branch,
dirty worktree) proving merged-clean is removed and unmerged/dirty survive.

Oracle: consumer = the user's morning launchd run; observable failure = an unmerged
branch or dirty worktree is deleted, or stale trash accumulates forever; oracle = the
filesystem/git state after running the real script against a fixture repo — git itself
(`git branch --list`, `git worktree list`) judges the outcome, independent of the
script's source.

Done when: purge and git-cleanup legs each have remove-and-survive test pairs in
`scripts_test.sh` (or a new focused file if `scripts_test.sh` sectioning demands);
suite green.

### P7 · herdr-child stub calibration visibility

The large herdr fake (`scripts_test.sh:2064-2548`) has no CI-reachable tether to the
real binary; the only calibration (test 1209) double-skips in Docker. Fix: extend the
1209 pattern to compare stub vs real result-envelope key sets for
`agent list`/`agent get`/`pane get` at the boundary the scripts consume, when a real
herdr is available; in the disposable-home gate convert the silent skip to a
`mms_disposable_home_verdict`-style hard fail (pattern of `test_scripts_100`,
:4910-4921) OR document why herdr cannot be installed there and keep a visible skip.

Oracle: consumer = ~200 herdr-child/pane-labels tests trusting the stub; observable
failure = upstream herdr renames a field and deployed watchers break while the suite
stays green; oracle = the real herdr binary's JSON output — the independent side the
stub is compared against.

Done when: calibration covers the three envelopes; its skip is visible or converted to
a hard fail in the environment that controls its deps; suite green on this host with
real herdr present.

### P8 · Remove source-shape greps in `scripts_test.sh`

Delete the source-text greps in `test_scripts_1119` (:5559-5562) and the source-absence
grep tail of `test_scripts_1057` (:1825-1826) — their behavioral halves already own
those contracts. Fold `test_scripts_1001` (:1291-1304, `declare -F` existence checks)
into the behavioral tests 1002/1003 or delete it.

Oracle: deletion-only; the remaining behavioral assertions in the same tests are the
coverage owners. No new tests.

Done when: greps gone, behavioral halves intact, suite green.

### P9 · Split multi-scenario tests

Tests 033 (:2935), 036 (:3065), 037 (:3097), 040 (:3167), 068 (:4365), 069 (:4387) in
`scripts_test.sh` pack 2-3 scenarios with mid-test `teardown; setup`; a leg-1 failure
silently retires legs 2-3. Split each into one function per scenario, preserving every
assertion.

Oracle: refactor of test structure only; assertion set before == after (verify by
diffing assertion lines). No new tests.

Done when: each scenario is its own named test; total assertion count unchanged; suite
green.

### P10 · herdr-integrations present-leg

`test_scripts_093` (:4788-4797) tests only the herdr-absent skip path. Add the
herdr-present leg: stub `herdr` on PATH, assert the refresh commands it receives (same
pattern as neighboring cutover tests).

Oracle: consumer = chezmoi apply refreshing agent-state integrations; observable
failure = the refresh silently stops issuing commands when herdr is present; oracle =
argv recorded by the stub binary.

Done when: present-leg test passes; absent-leg untouched; suite green.

### P11 · Re-home the checkout colony in `smoke_test.sh`

(a) Focus-notify behavior tests 033-035 (:638-722) run the checkout `notify.py`; point
them at the deployed copy `$HOME/.config/herdr/plugins/herdr-focus-notify/notify.py`
(gate on `is_macos` like siblings), or run both with deployed as the primary.
(b) Move tests 007/008 (:198-260, checkout script under fake herdr/uname) into
`scripts_test.sh`.
(c) `smoke_test.sh` test 1057 (:902-906) is the sole runner of
`tests/pi-brew-auto-update.test.ts` and runs it against the checkout: add a direct bun
Makefile target for the source suite (pattern of `Makefile:40-55` siblings) and make
1057 parameterize on the deployed path like 1055/1065/1068-1070, or drop it if the
deployed run is added elsewhere.

Oracle (a): consumer = herdr executing the deployed plugin; observable failure = a
chezmoi ignore rule drops `notify.py` from deployment while checkout tests stay green;
oracle = executing the deployed file itself. (b)(c) are re-homing; existing oracles move
with the tests.

Done when: deployed focus-notify is executed by tests on macOS; 007/008 live in
`scripts_test.sh`; the bun suite has a checkout runner independent of smoke; both
suites green.

### P12 · Brewfile full-render controls

`templates_test.sh` tests 021/022 (:594-633) assert the full render but never pin
`gitleaks`, `node`, `bun` — the entries asserted only in the minimal render. A template
edit wrapping them in the `ci_minimal` guard passes everything while real hosts stop
installing a security scanner. Add the three `assert_line` controls to the full-render
test, mirroring the symmetric-pinning comment at :605-608.

Oracle: consumer = a real host's `brew bundle`; observable failure = `gitleaks`/`node`/
`bun` silently leave the install set; oracle = the rendered Brewfile produced by real
chezmoi — the render is the independent side (two-sided mode matrix already exists).

Done when: full render pins all entries the minimal render refutes/asserts
asymmetrically; both mode renders green.

### P13 · Rework the smoke grep zone (1052, 1058, 1061, 1062, label-writer helper)

(a) Test 1052 (:766-787): drop the SKILL.md prose greps and the `--name`
source-absence greps; if the reap/verify/reply flow matters, keep at most the one
command string agents copy verbatim, or replace with a behavioral check through the
herdr-child fakes.
(b) Tests 1061/1062 (:1102-1154): keep the `include ... | sha256sum` hash-input
contract but derive the include list from the templates themselves (technique of
`templates_test.sh` test 027, :705-724) instead of a hand-copied six-entry inventory;
drop the internal-function-name greps (`^hpl_cutover_rollback()` etc.).
(c) `assert_herdr_label_writer_contract` (:996-1048): remove the word-ban greps
(:1030-1035, :1098) and the `icon|glyph|nerd font` keyword grep; keep the
single-writer `herdr pane rename` count and the octal-glyph literals with their
negative control.
(d) Drop test 1058 (:1050-1056), keeping 1059 as the deployed owner — the engine's
behavior is owned by ~40 `scripts_test.sh` tests.

Oracle: mostly deletion of shape assertions whose behavioral owners exist and are
named; the derived-include change compares two independent sides (template's own
include lines vs plugin directory listing) with no hand copy.

Done when: no doc-prose greps, no absence-greps, no function-name greps remain in the
zone; derived include check catches a deliberately dropped include (verified during
development); suite green.

### P14 · Visible skips instead of silent `return 0`

`smoke_test.sh:165` (test 004 chezmoi-membership half) and :671 (test 032 deployed-
manifest half) drop assertions via `command_exists || return 0` / `is_macos ||
return 0`, invisible to skip-identity comparison. Convert to `skip "<reason>"` or split
each into two tests so the lost half is visible.

Oracle: honesty fix; existing assertions unchanged.

Done when: a reduced-environment run reports these as skips, not passes; suite green.

### P15 · Deduplicate and unfreeze

(a) Registration dedup: `herdr-agent-state.sh` SessionStart asserted 4×. Keep one
deployed owner (fold test 1054's tail into 1064 or vice versa); in `templates_test.sh`
keep 0154's registration conjunction OR the per-test asserts — not both: per the
cross-review, drop 0154 (its three facts are each owned by 0151/0152) and keep
0151/0152's unique `source-path` resolution checks.
(b) Remove `templates_test.sh` 0095 (:311-333, owned by `chezmoi_unattended_test.sh`
test 002) and the third block of 0094 (:300-309, repeats 0092's diff).
(c) Drop pure-absence test 1053 (`smoke_test.sh:789-795`); keep 1054's paired
absence+positive as the single retirement owner; trim the duplicate retirement asserts
in 1063/0151 where they have no positive pairing.
(d) Unfreeze preferences: test 017 (:384-397) theme names → referential-integrity
assertion (settings-named theme resolves to a deployed theme file); test 024 (:530)
`include Alabaster.conf` pin → drop or convert to "references a theme file that
exists".
(e) Upgrade test 1056 (:896-900) to run the Pi extension's focused bun suite against
the deployed path via env override (pattern of 1065/1068-1070).
(f) Add unrendered-`{{` guards to `templates_test.sh` 0151/0152 renders (pattern of
:90, :207-208).

Oracle: (a)-(c) deletion with named surviving owners; (d) the referential check
compares two independent sides (settings value vs deployed file tree); (e) the bun
suite is the oracle, pointed at the deployed artifact; (f) rendered output free of
template syntax, judged by real chezmoi render.

Done when: each retired assertion has a named surviving owner in the plan-item commit
message; suite green.

### P16 · Small-suite fixes

(a) `herdr_pane_labels_descriptor_probe_test.sh`: dead bats-style `teardown` hook —
add `function tear_down() { _bats_run_teardown; }` and
`function tear_down_after_script() { _bats_file_cleanup; }` (siblings' pattern), or
delete the dead hook with a comment explaining deferred cleanup; add the one-line
header naming `test_scripts_1103` as its driver.
(b) `platform_test.sh`: add a positive cross-platform control (e.g. `.zshenv` present)
to the refute-only Linux leg of test 001; derive the expected macOS-only set from
`.chezmoiignore`'s darwin block instead of the hand-copied list (reconciling the
001/002 asymmetry: `Library`, `kitty`); add a case for the Linux-only section
(`.chezmoiscripts/linux` filtered on macOS).
(c) `test_dsl_parallel_isolation_probe_test.sh`: skip with a message when not running
under its parallel driver, so a direct sequential invocation reports a skip instead of
a 5-second stall and false red.
(d) `idempotent_test.sh:298`: widen the YAML matcher to tolerate quoted values
(`MMS_DISPOSABLE_HOME: '1'`).

Oracle (b): two independent sides — `.chezmoiignore`'s own darwin block vs `chezmoi
managed` evaluation; a newly added darwin-only path is caught without editing the test.
(a)(c)(d) are fixture/matcher fixes with existing oracles.

Done when: probe cleanup runs (verify tmp root removed after a nested run); platform
test derives its inventory; sequential probe run skips; suite green.

## Progress

- [x] P1 · stall-proof chezmoi_unattended test 009
- [x] P2 · launcher guard + failure-propagation coverage
- [x] P3 · smart_close.py behavior tests
- [x] P4 · palette ranking onto fixtures + scroll consolidation
- [x] P5 · untested palette run paths
- [x] P6 · morning-cleanup destructive legs
- [ ] P7 · herdr-child stub calibration visibility
- [x] P8 · remove source-shape greps in scripts_test.sh
- [ ] P9 · split multi-scenario tests
- [ ] P10 · herdr-integrations present-leg
- [ ] P11 · re-home checkout colony in smoke_test.sh
- [x] P12 · Brewfile full-render controls
- [x] P13 · rework smoke grep zone
- [x] P14 · visible skips instead of return 0
- [ ] P15 · deduplicate and unfreeze
- [x] P16 · small-suite fixes
