# Revmux dual-model roster experiment

Status: IN PROGRESS.

Issue: [#353](https://github.com/Seigiard/my-mac-setup/issues/353)

Snapshot: 2026-10-05, frozen after the round completed at
`2026-10-05T13:01:56+02:00`. A later in-progress round had an unreadable empty
manifest and is not part of this snapshot.

## Question

Does running each `lean` lens group once on Claude and once on Codex find real
issues that one model alone misses often enough to justify the duplicate?

This snapshot covers every complete full-roster `dual-model` round in the
machine archive, across all projects. It does not restrict the corpus to this
repository because the profile is a machine-wide default and the experiment is
about the two executors' behavior on ordinary work.

## Interim verdict

Keep all five groups duplicated while the experiment remains active.

- 33 complete rounds over 25 tasks produced 965 find-stage candidates, 281
  synthesized records, and 272 verified records. The final report contained
  229 actionable findings, 39 immaterial findings, and 4 pre-existing findings.
- 45 actionable findings survived with exactly one source. Manual semantic
  comparison of all 45 against the opposite model's original candidates found
  43 genuine pair-unique findings, 2 synthesis merge misses, and no ambiguous
  cases.
- Every lens group received genuine unique findings from both models. The 43
  genuine pair-unique findings include 9 major and 34 minor findings.
- The evidence establishes added coverage, but not yet whether that coverage
  beats the cost. The archive has no billing data and no paired `lean` baseline
  over the same diffs. Keep collecting cost evidence before folding the roster
  into `lean` or restoring the machine default.

The current evidence does not support dropping either model from any group.
The weakest severity case is `lean`: its eight genuine unique findings are all
minor. The strongest is `adversarial`: five genuine unique findings include
three majors.

## Corpus gate

A round is included only when:

- `manifest.json` names the `dual-model` profile;
- the roster is exactly the five Claude/Codex pairs, ten agents total;
- `stages/1-found.json`, `stages/2-synthesized.json`,
  `stages/3-verified.json`, `findings.json`, and `events.jsonl` all exist;
- find-stage sources report `expected=10`, `reported=10`, and no degraded
  sources;
- neither the manifest nor any agent is marked degraded.

All 33 completed dual-model rounds passed this gate. Six agent retries occurred
in the first 30 rounds inspected, but all eventually reported; retry alone is
not degradation. The aggregator also cross-checks every manifest `raised`
count against the find-stage source inventory. This snapshot has no mismatch.

Run the reproducible inventory with:

```sh
python3 scripts/analyze_revmux_dual_model.py > /tmp/revmux-dual-model.json
```

The script deliberately does not guess semantic equivalence. It emits the
single-source actionable inventory for manual adjudication.

## Reproduction handoff

The archive can contain private repository names, paths, prompts, and findings.
Do not commit it, attach it to a public issue, or paste raw analyzer output into
this repository. Transfer it directly between trusted machines.

On the source machine, freeze a copy so a live review cannot change the
denominators while the benchmark runs:

```sh
snapshot=$(mktemp -d)/revmux-tasks
mkdir -p "$snapshot"
rsync -a "$HOME/.local/state/revmux/tasks/" "$snapshot/"
tar -C "$(dirname "$snapshot")" -czf revmux-tasks.tgz "$(basename "$snapshot")"
```

Move `revmux-tasks.tgz` through the trusted transfer channel used for the
projects represented in the archive. On the destination machine:

```sh
snapshot=$(mktemp -d)
tar -C "$snapshot" -xzf revmux-tasks.tgz
python3 scripts/analyze_revmux_dual_model.py "$snapshot/revmux-tasks" \
  > /tmp/revmux-dual-model.json
jq '{corpus, rounds, totals: (.totals | del(.single_source_actionable))}' \
  /tmp/revmux-dual-model.json
```

Require `raised_mismatches == []`. Investigate every rejected round rather
than silently including it. An unreadable manifest usually means a review was
still running when the snapshot was taken; take a new frozen snapshot after it
reaches a terminal state.

Semantic adjudication is the manual half of the benchmark:

1. Read `totals.single_source_actionable` from the JSON output.
2. For each row, derive the opposite partner in the same group, then read that
   round's `stages/1-found.json`.
3. Compare the singleton's title, body, file, line, cause, and failure mode with
   every original candidate from the opposite partner. Do not match on IDs.
4. Classify it as `A` (no semantic equivalent), `B` (synthesis failed to merge
   an equivalent), or `C` (ambiguous).
5. Search the other groups from the opposite model in the same round. Record
   pair-level and whole-model uniqueness separately.
6. Reconcile `A + B + C` exactly to the emitted singleton count and report
   severity plus verifier verdict per group and model.

Keep `confirmed` and `refined` separate from independent truth: they are
pipeline verdicts. Re-check a declared sample against each historical checkout
before making a claim about finding accuracy. The archive alone can measure
retention and overlap, not correctness or billing cost.

## Per-round inventory

`Final total` includes actionable, immaterial, and pre-existing records. A
smaller synthesis row count combines semantic merges and drops; subtraction
cannot distinguish them.

| Task / round | Find | Synth | Final actionable | Final total | Wall min |
|---|---:|---:|---:|---:|---:|
| R01 | 11 | 3 | 1 | 2 | 14.6 |
| R02 | 45 | 13 | 10 | 12 | 18.1 |
| R03 | 21 | 11 | 4 | 10 | 17.5 |
| R04 | 46 | 16 | 14 | 16 | 18.4 |
| R05 | 50 | 16 | 16 | 16 | 25.0 |
| R06 | 34 | 11 | 8 | 11 | 18.2 |
| R07 | 0 | 0 | 0 | 0 | 5.6 |
| R08 | 14 | 2 | 2 | 2 | 9.1 |
| R09 | 13 | 3 | 1 | 2 | 6.9 |
| R10 | 33 | 7 | 6 | 7 | 8.8 |
| R11 | 41 | 9 | 9 | 9 | 8.7 |
| R12 | 26 | 8 | 5 | 8 | 13.4 |
| R13 | 50 | 14 | 12 | 13 | 12.8 |
| R14 | 36 | 10 | 8 | 9 | 12.9 |
| R15 | 42 | 11 | 8 | 11 | 17.4 |
| R16 | 7 | 4 | 3 | 4 | 9.3 |
| R17 | 26 | 9 | 8 | 8 | 13.3 |
| R18 | 31 | 8 | 7 | 8 | 8.0 |
| R19 | 25 | 6 | 6 | 6 | 12.4 |
| R20 | 0 | 0 | 0 | 0 | 3.7 |
| R21 | 22 | 7 | 6 | 7 | 5.7 |
| R22 | 25 | 4 | 4 | 4 | 12.3 |
| R23 | 11 | 2 | 2 | 2 | 9.0 |
| R24 | 63 | 22 | 19 | 21 | 15.2 |
| R25 | 6 | 3 | 2 | 3 | 6.1 |
| R26 | 0 | 0 | 0 | 0 | 6.7 |
| R27 | 93 | 25 | 19 | 25 | 16.6 |
| R28 | 52 | 14 | 12 | 14 | 13.3 |
| R29 | 38 | 11 | 10 | 11 | 9.7 |
| R30 | 21 | 8 | 6 | 8 | 9.2 |
| R31 | 23 | 6 | 5 | 5 | 11.7 |
| R32 | 18 | 5 | 4 | 5 | 8.3 |
| R33 | 42 | 13 | 12 | 13 | 21.3 |
| **Total** | **965** | **281** | **229** | **272** | **399.5** |

## Model comparison

`Synth source membership` counts synthesized records whose merged source list
contains that agent. It is not a unique-finding count. `Paired final` counts
final records that contain both halves of the named group.

| Lens group | Find C / X | Synth source membership C / X | Paired final | Single-source actionable C / X | Genuine pair-unique C / X |
|---|---:|---:|---:|---:|---:|
| bugs+impl | 103 / 75 | 97 / 74 | 32 | 2 / 3 | 2 / 3 |
| arch+quality | 140 / 76 | 118 / 76 | 37 | 6 / 4 | 5 / 4 |
| docs+tests | 133 / 82 | 114 / 82 | 38 | 9 / 8 | 8 / 8 |
| adversarial | 107 / 74 | 98 / 74 | 39 | 1 / 4 | 1 / 4 |
| lean | 107 / 68 | 94 / 68 | 30 | 5 / 3 | 5 / 3 |
| **Total** | **590 / 375** | **521 / 374** | n/a | **23 / 22** | **21 / 22** |

The find stage is asymmetric: Claude raised 590 candidates and Codex raised
375. That does not translate into one-sided value. After synthesis and verify,
Claude contributed 21 genuine pair-unique actionables and Codex contributed 22.

## Semantic adjudication

All 45 final actionable findings with exactly one source were checked against
every original find-stage candidate from the opposite model in the same lens
group and round. The check then looked across the other groups on the opposite
model to distinguish pair-level from model-level uniqueness.

A match required the same causal defect and failure mode. Sharing a file,
requirement, or broad topic was not enough.

| Lens group | Singletons C / X | Genuine C / X | False unique C / X | Major / minor |
|---|---:|---:|---:|---:|
| bugs+impl | 2 / 3 | 2 / 3 | 0 / 0 | 1 / 4 |
| arch+quality | 6 / 4 | 5 / 4 | 1 / 0 | 3 / 7 |
| docs+tests | 9 / 8 | 8 / 8 | 1 / 0 | 2 / 15 |
| adversarial | 1 / 4 | 1 / 4 | 0 / 0 | 3 / 2 |
| lean | 5 / 3 | 5 / 3 | 0 / 0 | 0 / 8 |
| **Total** | **23 / 22** | **21 / 22** | **2 / 0** | **9 / 36** |

The two false uniques were synthesis merge misses:

1. R27: `docs+tests-claude` reported that the test did not prove permanent selection
   removal; `docs+tests-codex` reported the same invariant through the restored
   row becoming selected again.
2. R28: `arch+quality-claude` reported stale documentation
   around exhausted takeover handling; `arch+quality-codex` reported the same
   direct-`claim` caller failure and required fix.

Representative genuine uniques include:

- `adversarial-claude`, major/refined: a module-scope runtime path lookup broke
  test-runner imports after code moved between repositories.
- `adversarial-codex`, major/confirmed: a workflow invoked an unavailable and
  forbidden routine.
- `bugs+impl-claude`, major/refined: a rewind path erased an answer and left the
  record stuck.
- `arch+quality-codex`, major/confirmed: lookup requirements rejected valid
  delegated targets.
- `docs+tests-claude`, major/confirmed: a reopened record was immediately
  closed with an incorrect human-action reason.
- `docs+tests-codex`, minor/refined: a request-cap test could pass when a new
  page arrived during pending reads.
- `lean-claude`, minor/confirmed: a handoff named a nonexistent API.
- `docs+tests-codex`, minor/refined: a first-only permission fixture allowed a
  positional implementation to pass.

Three pair-unique findings had clear equivalents from another group on the
opposite model, and two had partial cross-group overlap. On a strict causal
match, 42 of the 45 single-source actionables were unique to one model across
the entire roster. Counting partial overlap broadly lowers that to 40 of 45.

## Pipeline behavior

- Find to synthesis: 965 to 281, a reduction of 684. This combines merges and
  drops; it is not a false-positive count.
- Synthesis to verify: 281 to 272. Verification removed 9 IDs.
- Final disposition: 229 actionable, 39 immaterial, 4 pre-existing.
- Final actionable severity: 3 critical, 71 major, 155 minor.
- The 45 manually checked single-source actionables were 9 major and 36 minor;
  26 were confirmed and 19 refined.
- 107 final records had at least one Claude and one Codex source, showing that
  the duplicate often corroborates as well as expands coverage.

The archive cannot establish whether duplication raises false-positive rate.
There is no same-diff single-model control, and pipeline `confirmed` is not an
independent correctness oracle. The semantic adjudication above checks overlap,
not whether each underlying code claim was objectively correct.

## Time and tokens

- Total wall time: 23,972,039 ms, or 6h 39m 32s.
- Mean wall time: 12m 6s per round.
- Find stage: 19,414,525 ms, 81.0% of wall time.
- Synthesis stage: 1,655,161 ms, 6.9%.
- Verify stage: 2,902,270 ms, 12.1%.
- Find-agent counters: Claude 364,743,852; Codex 14,964,994.
- Whole-pipeline counter: 428,068,149.

The token counters are not comparable spend measurements. The executors count
cached and context tokens differently, and the archive has no billing data.
Likewise, wall time cannot be called the duplicate's incremental cost without a
paired `lean` run over the same diff. The profile design predicts roughly twice
the find work, but this snapshot does not measure that delta.

## Next evidence

Before closing #353:

1. Capture actual billing or another executor-neutral cost measure for future
   rounds.
2. Pair at least a small sample of `dual-model` and `lean` runs over identical
   frozen diffs if incremental wall time is part of the acceptance decision.
3. Re-run the aggregator after each ordinary round and adjudicate only the new
   single-source actionables.
4. Decide whether eight minor-only `lean` uniques justify that pair's cost.
5. Restore the machine default and concurrency settings only after the roster
   decision is recorded.

## Caveats

- This is a cross-project corpus. It measures the model pairing on the work the
  machine actually reviewed, not only this repository's shell/config domain.
- Final source lists reflect synthesis. Manual review found two merge misses in
  45 apparent singletons, so source-list subtraction alone overstates
  uniqueness.
- Semantic adjudication used archived finding text and stage transitions. It
  did not re-check every claim against the historical checkout.
- `confirmed` and `refined` are pipeline judgments, not independent ground
  truth.
- The archive is live. This report intentionally freezes a named completion
  boundary so later rounds do not silently change its denominators.
