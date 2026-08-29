# Coverage review: Bats → bashunit one-to-one scenario mapping

Independent static review (greps and file reads only; no bats/bashunit/docker runs).
Date: 2026-08-28. Reviewer: independent coverage agent.

## 1. Scenario counts and manifest reconciliation

Independent recount (`^@test` regex, every line parsed cleanly — no unparsed
`@test` variants):

| Oracle file | @test blocks | Manifest rows | Generated `function test_*` defs |
|---|---|---|---|
| tests/smoke.bats | 74 | 74 | 74 (smoke_test.sh) |
| tests/scripts.bats | 254 | 254 | 254 (scripts_test.sh) |
| tests/palette.bats | 57 | 57 | 57 (palette_test.sh) |
| tests/platform.bats | 2 | 2 | 2 (platform_test.sh) |
| tests/idempotent.bats | 13 | 13 | 13 (idempotent_test.sh) |
| **Total** | **400** | **400** | **400** |

Programmatic reconciliation (Python over manifest.tsv, oracle files, generated
files):

- All 400 manifest rows are well-formed (5 tab-separated fields).
- Per file, manifest indexes are gapless 1..N and each row's description is
  byte-identical to the oracle `@test` name at that position. Zero mismatches.
- Every row's generated-file attribution matches `<oracle-basename>_test.sh`.
- Every manifest function name has a matching `function <name>()` definition in
  its attributed generated file (0 missing).
- Reverse direction: every `test_*` function defined in the five generated
  files has exactly one manifest row (0 orphans).

**Verdict: the mapping reconciles exactly, both directions.**

## 2. Function-name collision (one found)

`test_001_python3_is_present_and_at_least_3_9_the_floor_re` is defined **twice**
— once in `tests/bashunit/smoke_test.sh` and once in
`tests/bashunit/palette_test.sh`. Both oracles open with the identical scenario
name "python3 is present and at least 3.9, the floor README.md declares", and
the name-truncation scheme in `scripts/bats2bashunit.py` produces the same
57-char function name for both.

Impact today: **latent, not active.** Every harness in the tree
(`run-post-apply-bashunit.sh`, `bench-bats-vs-bashunit.sh`,
`compare-suite-file.sh`) invokes bashunit one file per process, so the two
definitions never share a shell. But any future combined invocation
(`tests/lib/bashunit tests/bashunit/*_test.sh` in one call) would source both
files into one shell; the later definition shadows the earlier and one scenario
silently runs twice / the other zero times — exactly the class of silent
coverage loss this manifest exists to prevent. Recommendation: disambiguate the
generator's truncation (e.g., include a file prefix or hash suffix on
collision) and regenerate.

## 3. Skip semantics

18 distinct `skip "..."` messages in the oracle files. Every one survives
verbatim (same quoted string) in the generated files. Per-file `skip "` call
site counts match exactly:

| File | Oracle skips | Generated skips |
|---|---|---|
| smoke | 15 | 15 |
| scripts | 116 | 116 |
| palette | 0 | 0 |
| platform | 2 | 2 |
| idempotent | 2 | 2 |

No skip guard was dropped or reworded.

## 4. Probe files and residual runtime dependency on bats

`tests/herdr_child_descriptor_probe.bats` and
`tests/herdr_task_sync_descriptor_probe.bats` are not in either runner's file
set. References found:

- **`herdr_task_sync_descriptor_probe.bats`** — referenced by two scenarios in
  tests/scripts.bats, and a third scenario re-invokes scripts.bats itself:
  1. scripts.bats "herdr-task-sync descriptor probe lives in a one-test Bats
     file" (line 2416, manifest scripts #101 →
     `test_101_herdr_task_sync_descriptor_probe_lives_in_a_one`): runs
     `bats --count "$descriptor_probe_file"`.
  2. scripts.bats "herdr-task-sync bounded Bats invocation exits after
     detached work" (line 2426, manifest scripts #102): resolves
     `bats_bin="$(command -v bats)"` and drives a nested bats run of the probe
     file from Python.
  3. scripts.bats "herdr-task-sync bounded Bats invocation refuses a vacuous
     run" (line 2735, manifest scripts #103 →
     `test_103_herdr_task_sync_bounded_bats_invocation_refuses`): runs
     `bats "$BATS_TEST_FILENAME" --filter '^herdr-task-sync bounded Bats
     invocation exits after detached work$'`.
- **`herdr_child_descriptor_probe.bats`** — referenced by **nothing** in the
  tree (no .bats, .sh, .py, or Makefile reference). It is orphaned in both the
  bats and bashunit worlds; likely a leftover from the herdr-child parallel
  stabilization (commit 01a73d5). Its one scenario ("herdr-child detached
  watcher closes launcher descriptors and owns a process group") is currently
  dead coverage under both runners. Not a migration regression, but worth a
  repository issue.

**Post-migration consequence:** scenarios scripts #101–#103 keep a hard runtime
dependency on the `bats` binary being installed even after the suite runs under
bashunit. The converted bodies are verbatim, so:

- #101 and #102 still exercise the same property (they always targeted the
  standalone probe .bats file, which the migration keeps).
- #103 is subtler: the compat shim's `_bats_file_init` points
  `BATS_TEST_FILENAME` at the **oracle** `tests/scripts.bats`, so the converted
  test re-runs the *bats* implementation of scenario #102 under the pinned
  one-poll env, not the bashunit conversion of it. The asserted property (the
  guard in #102 goes red on a vacuous run) is still genuinely exercised — but
  against the bats copy. It therefore additionally depends on
  `tests/scripts.bats` remaining present and in sync. If the .bats oracles are
  ever deleted after cut-over, #103 breaks (and #102's non-vacuity guard loses
  its meta-test); the trio would need a bashunit-native re-expression.

## 5. Runner equivalence

`tests/run-post-apply.sh` vs `tests/bashunit/run-post-apply-bashunit.sh`:

- **Modes**: both accept exactly `full` / `host-safe`, print equivalent usage
  to stderr, and exit 2 on anything else. Same wording pattern.
- **File sets**: identical — full = smoke, scripts, palette, platform,
  idempotent; host-safe drops idempotent. Same order.
- **Parallelism**: bats runs one process with `--jobs 8
  --no-parallelize-across-files` (files sequential, ≤8 tests concurrent within
  a file; idempotent.bats additionally sets
  `BATS_NO_PARALLELIZE_WITHIN_FILE=true` at line 25). bashunit runs one
  invocation per file sequentially with `-j "${MMS_BASHUNIT_JOBS:-8}"`, and
  `idempotent_test.sh` carries the `# bashunit: no-parallel-tests` header
  (line 2). Semantics equivalent, with one intended divergence: the bashunit
  jobs count is overridable via `MMS_BASHUNIT_JOBS`; bats' is hard-coded.
- **Failure semantics**: bats aborts nothing either (it runs all files in one
  process and reports aggregate failure). The bashunit loop continues past a
  failing file and exits with the **last** nonzero rc (`|| rc=$?` then keeps
  looping) — a later-failing file's code wins, and rc stays nonzero once any
  file fails. Aggregate pass/fail is equivalent; the specific exit code may
  differ from bats' (cosmetic).

## Top findings (ranked)

1. **Duplicate function name across files** (smoke #1 vs palette #1) — latent
   shadowing hazard if files are ever sourced into one bashunit invocation;
   fix the generator's truncation-collision handling.
2. **scripts #101–#103 keep bats as a runtime dependency after migration**, and
   #103 specifically re-runs the *oracle* tests/scripts.bats via
   `BATS_TEST_FILENAME` — a hidden coupling that breaks if the .bats files are
   removed at cut-over.
3. **tests/herdr_child_descriptor_probe.bats is fully orphaned** — its scenario
   is dead coverage under both runners; needs a repository issue (pre-existing,
   not caused by the migration).

Everything else reconciles exactly: 400/400 scenarios, one-to-one, correct
attribution, verbatim skip guards, equivalent runner semantics.
