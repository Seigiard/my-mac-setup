---
title: Measure the cost, prove the equivalence, decline the rest
date: 2026-09-06
category: design-patterns
module: herdr
problem_type: design_pattern
component: testing_framework
severity: high
resolution_type: workflow_improvement
related_components:
  - tooling
  - development_workflow
  - ci
applies_when:
  - "A fork count, call count, or arithmetic extrapolation is about to be treated as a performance finding"
  - "A hot-path shell helper is being rewritten from a pipeline into parameter expansion or a single pass"
  - "A rewrite must preserve byte-for-byte output that no existing test pins"
  - "A measured win carries a dependency, correctness, or blast-radius cost"
  - "A wait loop counts its own iterations to decide when a budget has expired"
symptoms:
  - "A predicted saving of seconds measures zero when the change lands"
  - "A suite spends more time in sys than in user and behaves as a process-creation benchmark"
  - "A test cannot shorten a poll without also shortening the deadline it asserts"
  - "An A/B run's baseline varies more than the effect being measured"
tags:
  - performance
  - measurement
  - differential-equivalence
  - fork-overhead
  - poll-interval
  - shell-hot-path
  - herdr
---

# Measure the cost, prove the equivalence, decline the rest

## Context

PR #171 (merge commit `a59c3b4`, merged 2026-09-05, reachable from HEAD) landed three shell
performance changes at once: fork chains replaced in the state encode and field-read helpers
(issue `2026-09-05-001`), per-call subprocess and poll overhead cut from the test suite
(`2026-09-05-002`), and the only genuinely super-linear function in the repository rewritten into
one pass (`2026-09-05-003`).

The friction that produced them is specific to this repository's shape. The deployed code is bash
3.2 shell that runs under a large bashunit suite; the suite spends more time in `sys` than in `user`
(the 001 record puts it at 198s against 106s on a ten-core host), so it behaves as a
process-creation benchmark rather than a computation benchmark. In that regime a fork count *looks*
like a cost model. It is not one, and the three records together contain the counter-examples that
prove it is not.

What generalizes is not any of the three rewrites. It is the method the three records share: every
cost was measured before it was believed, every rewrite was proved output-identical differentially
before the suite was trusted to catch a regression, and three separately measured wins were
deliberately declined. A fourth thing fell out as a design shape rather than a fix: a wait loop that
counts its own iterations has fused two independent numbers, and un-fusing them is what made the
test suite able to sample faster without moving the deadlines it asserts.

## Guidance

### 1. Measure before you believe, and interleave the runs

Fork counts and call counts are hypotheses, not findings. Three data points from these records fix
that in place:

- **Arithmetic can predict a win that measures exactly zero.** The 002 record: "An earlier
  prediction of ~15 s from memoising `hpl_socket_dir` measured exactly zero (288.2 against 288.0
  CPU-s) because the suite is idle-bound at 0.30 of ten cores, so arithmetic extrapolation from fork
  counts is not evidence here." The forks were real. The saving was not, because the machine was
  waiting, not computing.
- **Arithmetic can also be exactly right and still not describe growth.** The 003 record measured
  the fork count of `build_worktree_tokens` as exactly n²: 36 at n=6, 144 at n=12, 576 at n=24. The
  *measured* growth was roughly n^1.7 — the exponent the forks predicted was not the exponent the
  clock reported, and after the rewrite growth is still about n^1.4, not linear, because
  `token_is_taken` (`home/dot_local/bin/executable_herdr-pane-labels:645-654`) still rescans the
  assigned mappings per candidate.
- **Predictions overshoot in the same direction.** Every per-item prediction in the 002 table came
  in larger than the measurement: the threshold hook's `sleep 1` was predicted at ~21.5 s wall and
  the family moved 8.98s to 6.22s; `run_npx`'s `sleep 0.2` was predicted at ~6.6 s and the skills
  family moved 3.90s to 3.61s; the pane-busy retry was predicted at ~4.9 s and measured no
  wall-clock win at all under `-j 8`.

The measurement discipline that produced trustworthy numbers here has three parts.

**Interleave, do not block.** The first attempt was thrown away, as the `a59c3b4` commit message
records rather than the 001 issue: "A blocked A/B run first was discarded: variance within the
baseline alone reached 15%, which is wider than the effect." The replacement was an interleaved
four-pair A/B.

**Report pairs, not means.** The accepted result is stated as "294.1 to 256.8 CPU-seconds (-12.7%)
and 104.89 to 97.28 seconds wall (-7.3%), every pair negative, paired standard deviation 5.7." The
load-bearing clause is *every pair negative*: it survives a host that drifts between pairs, which a
mean does not.

**Measure the metric the change actually moves.** The stub-script change measured -8.6% mean wall
across three pairs while CPU-seconds moved inconsistently (-0.02, -9.20, -2.31). The right
conclusion was recorded rather than the better number: the win is in serialized file writes rather
than in computation.

**Numbers from different runs are not comparable, even for the same function.** The 003 record
contains two baselines for the same code on the same shape that differ by 1.4-2x and yield different
exponents (see *Figures that could not be corroborated* below). Neither is wrong; they were taken on
differently loaded hosts. This is the same fact that makes interleaving mandatory, seen from the
other side — a before-number from Tuesday and an after-number from Wednesday are not an A/B.

### 2. Prove equivalence differentially; the suite is the gate, not the proof

Both rewrites that changed output-producing code were proved byte-identical against the *previous
implementation*, over a generated corpus, before the existing suite was consulted:

- 189 probe lines for the encode/read helpers, covering empty values, unicode, inputs long enough to
  make `base64` wrap, values containing `=`, duplicate keys, files without a trailing newline, empty
  files, and missing files (001 Resolution).
- 198 generated corpora for `build_worktree_tokens`, covering duplicate roots, leading and doubled
  slashes, unicode and space-bearing components, names long enough to force the digest path, and
  randomized lists of up to 30 roots (003 Resolution).

The corpus categories are not decoration; each one names a way the *specific* rewrite could differ.
`base64` wraps at 76 columns, so a long input is the case where deleting newlines matters. A value
containing `=` is the case where `cut -d= -f2-` and `${line#*=}` could diverge. A file without a
trailing newline is the case the `|| [ -n "$line" ]` guard exists for. Duplicate roots are the case
where "distinct root" and "row" stop being the same thing.

The generated corpus and the suite answer different questions. The suite asks *did anything a test
pins change?* The corpus asks *did anything at all change?* For a rewrite whose whole claim is "same
output, fewer processes," only the second question is the claim.

**These harnesses do not survive in the tree.** A search of the repository finds no equivalence
harness, corpus generator, or probe-line driver from either rewrite, and `a59c3b4` adds no such file
— its changed files are three issue records, nine shell sources, and three test files. The harnesses
were throwaway. That is a deliberate choice with a real cost: the equivalence claim is now prose in
the issue records and the commit message, not something a later reader can re-run. It is defensible
for a one-shot rewrite of a helper whose old implementation is gone — a permanent harness would need
the deleted implementation kept alive to diff against, which is its own maintenance liability. It is
not defensible if the rewrite is expected to be revisited. Decide which case you are in, and say so.

### 3. Declining a measured win is part of the method

Three items were measured, found real, and not taken. Each remains declined in the current tree:

- **`python3` → `jq` for the pure-JSON accessors in `herdr-child-runtime.sh`.** Measured at ~18.5
  CPU-s across 889 accessor calls, 20.54 ms to 3.37 ms per call. Declined because `python3` must stay
  for the 193 `fcntl`-locking calls, so the swap would *add* a second hard dependency to the agent
  launch path rather than replace one. Still declined at HEAD:
  `home/dot_local/lib/herdr-child-runtime.sh` contains zero occurrences of `jq` and reads JSON
  through `python3 -c` at lines 184, 197, 215, 233, 253, 268, 281, 293, 346, 355, 363, 388, 398, 408,
  416, 425 and 466, with the `fcntl` locker at line 70. The reason is not performance; it is that a
  launch path with two interpreters has two ways to fail on a fresh machine.
- **`process_start_token`.** 0.75 CPU-s, declined because it writes straight into a lock file, so
  changing its trailing newline risks more than the fork it saves. Still `ps … | sed` at
  `home/dot_local/lib/herdr-worktree-state.sh:82-84` and
  `home/dot_local/bin/executable_herdr-pane-labels:186-188`, and the lock write it feeds is at
  `executable_herdr-pane-labels:1782`.
- **Collapsing `$(namespace_dir)` at its call sites.** The fork count was exact — 2898 subshells per
  run — but the A/B was swamped by ±14 CPU-s of host noise against a predicted 2.5 s gain. The 001
  record classifies it correctly: "a correctness-neutral tidy, not a proven win." Twenty
  `$(namespace_dir` call sites remain under `home/`.

The generalization: an exact count is not a mandate. A win is worth taking when (a) it measures
above host noise, (b) it does not widen the dependency surface of a path that has to work on a cold
machine, and (c) its blast radius on failure is proportionate. Failing any one of those, record the
measurement and the decline together so nobody re-derives it.

There is a fourth, subtler case. The child launcher's pane-busy retry gained the poll-interval
override and measured **no** wall-clock win under `-j 8`, because its one-second sleeps overlap other
tests and never enter the critical path. It was kept anyway — as *correct*, not as a saving, and the
record says so explicitly. Keeping a change whose measured benefit is zero is fine when its
justification is consistency; what is not fine is booking it as a performance win.

### 4. A poll interval is not a deadline

The design shape that fell out of 002: three wait loops decided a budget had expired by counting
their own iterations — `waited=$((waited + 1))` next to a `sleep 1`, and `tick / 5` next to a
`sleep 0.2`. That fuses two independent numbers. The sleep length *is* the clock, so a test cannot
shorten the sampling without also shortening the deadline it is asserting, and every such test pays
the full production interval.

The fix is to take the budget from bash's `SECONDS` — elapsed wall time, independent of how often
the loop wakes — and expose the interval as its own overridable variable. Deadlines are unchanged;
only the sampling rate moves.

```bash
# home/private_dot_claude/hooks/executable_context-threshold.sh:91-114
# SECONDS is bash's elapsed-time counter, so the deadline holds however often
# the loop samples. Counting iterations made the poll interval double as the
# clock, which is why the interval could not be shortened without moving the
# deadline with it.
started=$SECONDS
while kill -0 "$pid" 2>/dev/null; do
  if [ "$((SECONDS - started))" -ge "$seconds" ]; then
    ...
  fi
  sleep "$CONTEXT_THRESHOLD_POLL_INTERVAL"
done
```

The overrides in the current tree, with their defaults:

| Variable | Default | Defined at |
|---|---|---|
| `CONTEXT_THRESHOLD_POLL_INTERVAL` | `1` | `home/private_dot_claude/hooks/executable_context-threshold.sh:69` |
| `CONTEXT_THRESHOLD_KILL_GRACE_SECONDS` | `3` | `home/private_dot_claude/hooks/executable_context-threshold.sh:71` |
| `SKILLS_POLL_INTERVAL` | `0.2` | `home/dot_local/bin/executable_skills:20` |
| `HERDR_CHILD_PANE_BUSY_RETRY_DELAY` | `1` | `home/dot_local/bin/executable_herdr-child:35` |

`SKILLS_TIMEOUT` (`home/dot_local/bin/executable_skills:16`, default `600`) stays the deadline and is
compared against `SECONDS` at `executable_skills:131-135`; `terminate_tree` does the same against a
5-second bound at `executable_skills:110-113`. The launcher retry uses its delay at
`home/dot_local/lib/herdr-child-launch.sh:343`.

The pane-labels harness was not converted. `tests/helpers/herdr_pane_labels.bash:755-757` and `:813`
still derive poll *counts* from a stated ceiling and a stated interval (`HPL_WAIT_POLLS`,
`HPL_WAIT_SLOW_POLLS`, `HPL_WAIT_MATCH_POLLS`, `HPL_BLOCKED_HERDR_POLLS`, consumed as
`block_attempts` at `:219`). That is the middle form, not the fused one: both numbers are named and
the derivation is explicit, so shortening the interval does not move the ceiling. It is still one
conversion short of the `SECONDS` shape above.

**Leave one test on the production interval.** The suite exports `SKILLS_POLL_INTERVAL=0.01`
file-wide (`tests/bashunit/scripts_test.sh:8496`) and passes
`CONTEXT_THRESHOLD_POLL_INTERVAL=0.02 CONTEXT_THRESHOLD_KILL_GRACE_SECONDS=1` into the hook
(`tests/bashunit/scripts_test.sh:10056-10057`, `:10322-10323`) — but the one test that *proves*
`SKILLS_TIMEOUT` builds its environment from scratch (`tests/bashunit/scripts_test.sh:8797-8802`,
`"SKILLS_TIMEOUT": "2"`, no poll override) and still burns the real budget, asserting return code
124 at `:8815`. The comment at `scripts_test.sh:8491-8495` records exactly this. Shortening the
sampling everywhere would otherwise leave nothing exercising the real timeout path.

This is a *different* conflation from the one in
`docs/solutions/design-patterns/idle-machine-wall-clock-bounds-are-latent-flakes.md`. That document
is about one wall-clock number serving as both hang guard and behavioral assertion — two *roles* for
one bound. This is one number serving as both sampling granularity and deadline — two *mechanisms*
in one literal. They rhyme, and the fix rhymes too (separate the numbers, keep the one that is the
contract aligned with production), but the failure modes differ: the first produces flakes and false
greens, the second only produces a slow suite that cannot be sped up without weakening what it
asserts.

### 5. Related shapes worth reusing

Two mechanical patterns from the rewrites are worth naming, because both were the *enabling* move
rather than the optimization itself.

**Re-emit annotated rows rather than looking them up.** The single-`awk`-pass rewrite
(`worktree_root_analysis`, `home/dot_local/bin/executable_herdr-pane-labels:663-699`) does not return
a map for the caller to query — it re-emits every input row in input order with two extra fields,
and the caller consumes it with one `read` (`build_worktree_tokens`, `:701-744`, the read at `:705`).
The rows carry a trailing empty suffix field, because `read` strips a trailing separator, which would
otherwise have folded the count into the suffix for a root with no parent directory.

**Amortize invariant setup to file scope, then link.** Two independent instances landed. The
per-test Python bytecode cache became per-file: `set_up_before_script` makes one directory
(`tests/bashunit/palette_test.sh:1538-1541`), `setup` points `PYTHONPYCACHEPREFIX` at it with a
per-test fallback (`:39`), `tear_down_after_script` removes it (`:1543-1546`). And the four invariant
pane-labels stub scripts moved from being rewritten on every `hpl_setup` to being written once by
`hpl_setup_assets` (`tests/helpers/herdr_pane_labels.bash:73-459`, called from
`tests/bashunit/scripts_test.sh:9166-9167`), with each test getting **symlinks**
(`herdr_pane_labels.bash:491-494`). Symlinks rather than copies for a stated reason: the one test
that renames a stub to hide it from `PATH` moves its own link, not the shared target
(`herdr_pane_labels.bash:486-489`). A lazy build at `:490` covers files that load the harness without
the script-level hook.

## Why This Matters

**Believing a count instead of a clock wastes the expensive half of the work.** The `hpl_socket_dir`
memoisation was designed, argued, and predicted at ~15 s before it measured 0.0. Had it shipped on
the strength of its fork count, the repository would carry a permanent complexity cost — memoisation
is state, and state is a correctness surface — for nothing, and the next person profiling the suite
would find the same 288 CPU-seconds and no explanation of why the obvious fix is already present.
Recording the null result in the 002 record is what stops that repetition.

**A green suite is weak evidence for a rewrite that claims byte-identity.** The suite covers what
someone thought to pin. A rewrite from `grep -m1 … | cut -d= -f2-` to `${line#*=}` changes regex
semantics, empty-line handling, duplicate-key handling, and trailing-newline handling all at once;
`base64`'s 76-column wrap only appears above a length threshold no test may reach. The differential
corpus is the only artifact that answers the actual claim. Skipping it converts a performance change
into an unbounded behavioral change wearing a performance label.

**Declines carry as much information as wins.** "We did not swap `python3` for `jq`" is nearly
worthless. "We measured 18.5 CPU-s, and declined it because `python3` must stay for 193 `fcntl`
calls, so this adds a dependency instead of replacing one" is a decision that survives being
re-proposed. The 002 record and the commit message both state it, which is why the accessors are
still `python3` today and why the next reader does not need to re-measure.

**Fused numbers cost twice.** While the poll interval was the clock, every test that exercised these
loops paid the production interval — and the only way to make the suite faster was to weaken the
deadline the test existed to assert. Splitting them made the threshold family go from 8.98s to 6.22s
without changing a single deadline. The compounding cost of the fused form is not the seconds; it is
that the cheapest available speedup is also a silent reduction in what the suite proves.

## When to Apply

Apply this method when:

- You are about to justify a change with a fork count, call count, or per-call microbenchmark
  multiplied out. Measure the aggregate before you write the change, and again after.
- The workload's `sys` time rivals or exceeds its `user` time, or its CPU utilization is a small
  fraction of available cores. Both signals mean the cost model in your head is probably wrong.
- A rewrite claims to preserve output exactly and the old implementation is about to be deleted.
  Generate a corpus against the old code *before* deleting it.
- A measured win requires a new runtime dependency on a path that must work on a cold machine, or
  changes bytes written into a lock, claim, or state file.
- A loop's `sleep` value also appears in its termination condition, directly or through a divisor.

Do **not** apply the full ceremony when:

- The change is a pure deletion with no output (removing an unused fork, a redundant `mkdir -p`
  where `mkdir -p` on an existing directory already succeeds — see
  `home/dot_local/lib/herdr-worktree-state.sh:36-38`). Argue those from the failure paths they
  cannot reach, not from a benchmark.
- The effect is below the host's noise floor and the change is not otherwise justified. Record the
  measurement, mark it a tidy, and move on — as the `$(namespace_dir)` item was.

## Examples

### Encode helper: pipeline → parameter expansion

Before (`git show a59c3b4^:home/dot_local/lib/herdr-worktree-state.sh`, lines 6-8) — four processes:

```bash
encode_key() {
  printf '%s' "$1" | base64 | tr '/+' '_-' | tr -d '=\n'
}
```

After (`home/dot_local/lib/herdr-worktree-state.sh:6-17`) — two, the `tr` pair replaced by
parameter expansion, with the safety argument in the comment rather than in a commit nobody will
find:

```bash
encode_key() {
  # Parameter expansion rather than a tr pipeline. This runs on every state
  # path resolution, so the two forks it saves outweigh the work it does.
  # Deleting newlines before translating is safe: the classes '/+' and '=\n'
  # are disjoint, so neither step can see the other's characters.
  local encoded
  encoded="$(printf '%s' "$1" | base64)"
  encoded="${encoded//$'\n'/}"
  encoded="${encoded//\//_}"
  encoded="${encoded//+/-}"
  printf '%s' "${encoded//=/}"
}
```

The disjointness argument is what licenses reordering delete before translate. It is stated in the
source because a reader who does not know it will "simplify" the four expansions back into a
different order and silently change the output for a wrapped `base64` line. The same shape now
appears at `home/dot_local/lib/context-usage.sh:93-104` (`context_usage_encode_key`),
`home/dot_local/bin/executable_herdr-pane-labels:115-126`, and
`home/.chezmoitemplates/herdr-pane-labels-cutover-lib.sh:75-86` (`hpl_cutover_encode_key`).

### Field read: two greps → one scan that also counts

Before (`git show a59c3b4^:home/.chezmoitemplates/herdr-pane-labels-cutover-lib.sh`, lines 83-90) —
the file is read twice per field, once to count and once to fetch:

```bash
hpl_cutover_raw_field() {
  local file="$1" key="$2" count value
  [ -f "$file" ] || return 1
  count="$(grep -c "^${key}=" "$file" 2>/dev/null || true)"
  [ "$count" = 1 ] || return 1
  value="$(grep "^${key}=" "$file" 2>/dev/null)"
  printf '%s' "${value#*=}"
}
```

After (`home/.chezmoitemplates/herdr-pane-labels-cutover-lib.sh:94-110`) — one scan, no forks, and
the duplicate-key guard preserved by counting inside it:

```bash
hpl_cutover_raw_field() {
  # One scan counts the matches and keeps the first; the old form grepped the
  # same file twice per field to enforce the duplicate-key guard.
  local file="$1" key="$2" line count=0 value=""
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "${key}="*)
        count=$((count + 1))
        [ "$count" -eq 1 ] || return 1
        value="${line#*=}"
        ;;
    esac
  done < "$file" 2>/dev/null
  [ "$count" -eq 1 ] || return 1
  printf '%s' "$value"
}
```

The plain-read variant — first match wins, no duplicate guard — is at
`home/dot_local/lib/herdr-worktree-state.sh:51-66` (`read_state_field`),
`home/dot_local/bin/executable_herdr-pane-labels:288-303`, `:163-175` (`record_number`), and
`home/dot_local/lib/context-usage.sh:147-157` (`context_usage_field`). Every one of them carries the
`|| [ -n "$line" ]` guard, which is the whole reason "file without a trailing newline" was one of the
eight categories spanned by the 189 probe lines.

### `build_worktree_tokens`: n² forks → one

Before, the function found each root's shortest unique suffix by rescanning every other root at every
suffix depth, forking `awk` through `path_suffix` once per comparison. After, one pass
(`home/dot_local/bin/executable_herdr-pane-labels:663-699`) re-emits every row annotated with its
basename count and its shallowest non-colliding suffix, and `build_worktree_tokens` (`:701-744`)
consumes it row by row. The comment at `:656-662` records the equivalence argument that the
198-corpus diff then confirmed: "Distinctness matches the rescan it replaces: two identical root
strings never disqualify each other's suffix, while the basename count still counts every row."

Measured (003 Resolution): 6 roots 123→38 ms, 12 roots 406→107 ms, 24 roots 1600→286 ms, 48 roots
5782→674 ms. A single root costs 2 ms *more*, because the `awk` fork now runs unconditionally — a
regression the record states rather than omits.

## Figures that could not be corroborated

Every code-behavior claim above was read at HEAD. The measurements were not re-run, and three sets of
numbers do not agree across the records. This section is itself evidence for guidance 1: benchmark
figures decay into incomparability the moment they leave the interleaved run that produced them.

1. **The 003 baselines are internally inconsistent.** The "Why this exists" table gives 240 / 720 /
   2400 / ~7900 CPU-ms at 6 / 12 / 24 / 48 roots and calls the growth "roughly n^1.7." The Resolution
   gives the *pre-fix* side of its A/B as 123 / 406 / 1600 / 5782 ms and calls the previous growth
   "n^1.85." Same function, same shape, ~1.4-2x apart, with different exponents. Most likely
   different hosts or different load, but neither figure is re-derivable from the tree, and the
   record does not say which supersedes which.
2. **The 001 headline numbers differ between frontmatter and Resolution.** `short_description` says
   276.5 → 241.7 CPU-s (-12.6%) with "335/336 tests still passing"; the Resolution says 294.1 → 256.8
   (-12.7%) with "scripts 336/336." These read as the throwaway-tree investigation and the final
   landed A/B respectively — the Resolution says as much ("that reproduces the -34.8 figure the
   original investigation reported") — but the frontmatter is not marked as the earlier run.
3. **The 002 palette figures differ between frontmatter and Resolution.** `short_description` says
   "-10.8 CPU-s and -22% wall"; the Resolution says 20.4 → 8.93 CPU-s and 6.71 → 5.40 s wall
   (-19.5%). Same direction, different runs, not reconciled.

Two further scope notes:

- **The 002 Scope's smoke-test extension was not taken.** It says the file-scoped pycache change
  "applies at `tests/bashunit/smoke_test.sh:588` and `:650`." At HEAD, `smoke_test.sh:598` and `:660`
  still set `PYTHONPYCACHEPREFIX="$BATS_TEST_TMPDIR/pycache"` — per-test, not per-file. The
  Resolution does not mention it. Whether this was a deliberate decline or an oversight is not
  recorded anywhere.
- **Line anchors in the 001 record have drifted.** It cites `executable_herdr-pane-labels:1741` for
  the lock write and "eighteen call sites" for `$(namespace_dir)`; at HEAD the lock write is at
  `:1782` and there are 20 `$(namespace_dir` call sites under `home/`.

## Related

- `docs/solutions/design-patterns/idle-machine-wall-clock-bounds-are-latent-flakes.md` — the
  correctness half of the same wait-loop constants. Guidance 4 above is its cost-side complement:
  that document splits one bound's two *roles*, this one splits one literal's two *mechanisms*. Its
  "calibrate against the contention profile the suite creates" rule also explains this work's own
  null result, where the child-launcher retry showed no wall-clock win under `-j 8` because its
  sleeps overlap other tests.
- `docs/solutions/design-patterns/outliving-processes-hang-the-suite.md` — leaked pollers silently
  corrupt the very benchmark a performance session runs. That is a second reason the A/B must be
  interleaved and paired rather than sequential.
- `docs/solutions/design-patterns/skip-set-parity-proves-reduced-dependencies.md` — the prior
  instance of upgrading a proof obligation from "the suite went green" to a named empirical
  comparison. Guidance 2 is the same move applied to a rewrite instead of a dependency set.
- `docs/solutions/design-patterns/semantic-regression-tests-over-source-shape.md` — the oracle rule
  that a differential corpus against the previous implementation satisfies: the expected values come
  from code the patch does not edit, because they come from the implementation being replaced.
- `docs/agent-verification.md` — the gate these deployment-sensitive chezmoi-managed paths ran
  through (`make test-ubuntu`).
- Source records, all three `status: done`, closed 2026-09-05 and present at the time of writing:
  `docs/issues/2026-09-05-001-replace-fork-chains-in-state-encode-and-read-helpers.md`,
  `docs/issues/2026-09-05-002-cut-per-call-subprocess-and-poll-overhead-in-the-test-suite.md`,
  `docs/issues/2026-09-05-003-build-worktree-tokens-grows-super-linearly-with-worktree-count.md`.
  This repository prunes a closed issue once its lesson is compounded — precedent `13402c1`, "Clean up
  closed issues and consolidate solution into design patterns doc", and a later pruning that removed
  fifteen more — so these three are expected to go. Their evidence is reproduced inline above against
  that day; once they are pruned, reach them by ID through git history rather than by path.
- Open issues this method applies to: `2026-09-02-013` (palette herdr-stub tests flake at `-j 8`
  against a 2-second `HERDR_CALL_TIMEOUT_SECONDS` — a *deadline* problem, the boundary case showing
  which of the two fused numbers is at fault) and `2026-08-18-024` (three 0.2-0.4s palette focus
  sleeps that sequence nothing).
