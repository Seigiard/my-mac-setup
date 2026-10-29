---
title: Revmux scope instruction for test doubles, measurement for #577
type: benchmark
date: 2026-10-29
topic: revmux-benchmark-scope-577
status: measured
---

# Revmux scope instruction for test doubles, measurement for #577

Candidate 1 of issue #577: no prompt change, one section added to each round's `scope.md` that names every test double the diff touches or drives and what it stands for, "read in full, side by side" (`candidate-scope-section.md` shows the pair 4 text; `cases/` carry all six). Measured on the three labelled pairs of `lens-249/` against the unchanged managed `lean` profile. Result: not supported; the scope template and the profile stay as they are. Full page: [report](https://reports.1218217.xyz/reports/my-mac-setup/20261029T191034Z-26715094/index.html), Russian version in ASD-STE100 style: [отчёт](https://reports.1218217.xyz/reports/my-mac-setup/20261029T191037Z-959ad393/index.html). Both expire after 28 days; `report.py` and `report_ru.py` rebuild them from `metrics.json` and `verdict.json`.

## Setup

- Baseline: the 18 `lean` rounds of the #249 measurement (2026-10-28), reused rather than re-run: same frozen commits, same profile, same revmux 0.2.7 and scratch config (`~/.local/state/revmux-bench/408-pilot/config`). Candidate: 18 new rounds on 2026-10-29 (`driver.sh`, 2 × 3 × 3), none degraded; Claude weekly quota 43% → 45%.
- Cases and labels: `lens-249/cases/` with the candidate section appended, `labels.json` unchanged.
- Adjudication: one OpenCode gpt-5.6-terra agent per pair over all twelve rounds of the pair, six per arm, under opaque round ids (`xadj.py` builds the inputs and the sealed `adjudication/cross-arm/key.json`, included because the measurement is closed; `xscore.py` decodes them).

## Results

Final-list hits on the nine bad rounds per arm, false positives on the nine repaired rounds:

| Pair | Category | baseline hits | candidate hits | baseline FP | candidate FP |
| --- | --- | ---: | ---: | ---: | ---: |
| 2 | regression-insensitive | 2 of 3 | 3 of 3 | 0 | 0 |
| 3 | implementation-coupling | 0 of 3 | 0 of 3 | 0 | 2 |
| 4 | reimplemented-production-logic | 0 of 3 | 0 of 3 | 1 | 0 |

The candidate's two false positives on pair 3 are the finding the #249 lens block had also raised, now from `bugs+impl` and `arch+quality`: that the repaired tests take their expected alias from the allocator's own output; the adjudicator rejected it because the stub records the argument `herdr-child` passed, so the expectation is observed at the stub boundary. Pair 4, the defect the scope line was written for, was not named by any finder in either arm. Cost: 3.68M tokens per round against 3.26M (+13%), 5.1 minutes against 4.3.

The baseline rounds were judged twice (here and in `lens-249/adjudication/cross-arm/`): 15 of 18 round verdicts identical; the one scored difference is the pair 4 baseline false positive, counted here and not there.

## Files

`metrics.json` (per pair per arm, per-round verdicts, cost), `verdict.json` (the report prose), `labels.json`, `cases/`, `candidate-scope-section.md`, `driver.sh`, `codex-quota.sh` (the Codex weekly probe the driver uses), `collect.py`, `xadj.py`, `xscore.py`, `metrics.py`, `report.py`, `report_ru.py`, `adjudication/` (prompt template, the three verdict files and the key). Raw archives stay on the machine under `~/.local/state/revmux-bench/577-scope` and `577-xadj`.
