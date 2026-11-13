---
title: Revmux production trial of Terra beside Sol, for #576
type: benchmark
date: 2026-10-30
topic: revmux-benchmark-trial-terra
status: closed, Terra not adopted
---

# Revmux production trial of Terra beside Sol, for #576

One week of real review rounds, 2026-10-30 to 2026-11-06, under the `mixed-terra` profile: `mixed` with a gpt-6.1-terra twin of each codex group (`docs+tests`, `bugs+impl`, `lean`), nine agents. The two twins of a group carry the same lenses at the same effort and launch in the same wave, so a difference between them is the model's. The claude side is `mixed`'s, unchanged.

Why a trial. The [pre-registered holdout](../holdout-576/) failed Terra on one finding: 8 adjudicated-invalid findings in 15 rounds against a ceiling of 0.5 per round. The five majors that decided it all say "this test does not check X", and the owner reads that kind as valid when the change set out to cover X. Instead of re-adjudicating five findings, the trial puts both models on every real diff for a week.

## Results

Closed 2026-11-13 by the owner: `mixed` stays on gpt-6.1-sol, and the `mixed-terra` profile is removed. The tally covers 50 `mixed-terra` rounds, 2026-10-31 to 2026-11-13, none degraded and no model mismatch; 17 of them ran inside the trial week. The profile stayed the default until this decision, so the later rounds are the same measurement.

| Group | final_only, Sol | final_only, Terra | verified_rejected, Sol | verified_rejected, Terra | tokens, Sol | tokens, Terra |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| docs+tests | 41 | 39 | 3 | 14 | 4.39M | 2.51M |
| bugs+impl | 47 | 30 | 18 | 17 | 4.66M | 2.36M |
| lean | 38 | 13 | 1 | 9 | 4.44M | 2.32M |
| **all three** | **126** | **82** | **22 of 242 (9.1%)** | **40 of 216 (18.5%)** | **13.49M** | **7.19M** |

- Rule one fails: 82 final findings came from Terra and not from its Sol twin, 126 from Sol and not from Terra. Terra came close only in `docs+tests`; in `lean` Sol led three to one.
- Rule two passes at the edge: Terra's rejected share is 9.4 points above Sol's, against a limit of 10.
- Terra used 53% of Sol's tokens. The rule does not weigh cost, and the saving does not offset a third fewer final findings that only this twin raised.

`tally.py` still reads the archive by the `mixed-terra` name in each round's manifest, so the table reproduces without the profile file.

## What is compared

`tally.py` reads every `mixed-terra` round in `~/.local/state/revmux/tasks` and prints, per twin:

| Column | Meaning |
| --- | --- |
| raised, raised_major | findings the twin's own agent wrote at the finder stage |
| final, final_major | findings on the round's final list that name the twin among their sources |
| final_only_this_twin | final findings the twin sourced and its pair did not: what the round would have lost without it |
| verified_rejected | synthesized findings naming the twin that verification removed from the list |
| tokens | the manifest's per-agent counter, comparable within the codex vendor |

The decision at the end of the week is the owner's, on this table: Terra replaces Sol in `mixed` when its `final_only_this_twin` is at least Sol's across the three groups and its `verified_rejected` share of `final + verified_rejected` is not higher than Sol's by more than ten points; otherwise `mixed` stays on Sol. Either outcome is one PR that edits `mixed` or the config, with the tally output in its body. Fewer than ten rounds by 2026-11-06 extends the trial by a week.

```sh
python3 docs/benchmarks/revmux-harness/trial-terra/tally.py            # table
python3 docs/benchmarks/revmux-harness/trial-terra/tally.py --json     # for the PR body
```
