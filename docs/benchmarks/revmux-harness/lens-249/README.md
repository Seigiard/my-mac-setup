---
title: Revmux test-evidence lens measurement for #249
type: benchmark
date: 2026-10-28
topic: revmux-benchmark-lens-249
status: measured
---

# Revmux test-evidence lens measurement for #249

One candidate change to the `tests` lens, measured against the unchanged managed `lean` profile on three labelled pairs from the #249 seed ranges. Result: not supported; the lens stays as it is. Full page: [report](https://reports.1218217.xyz/reports/my-mac-setup/20261028T015719Z-e227a773/index.html), Russian version in ASD-STE100 style: [отчёт](https://reports.1218217.xyz/reports/my-mac-setup/20261028T044836Z-9bbdef84/index.html). Both expire after 28 days; `report.py` and `report_ru.py` rebuild them from `metrics.json` and `verdict.json`.

## Setup

- Baseline: the managed `lean` profile, embedded `tests` lens. Candidate: the same profile with one twelve-line block appended to the `tests` lens (`candidate-block.md`; the whole lens as run is `candidate-tests-lens.md`). The diff of the composed `docs+tests` finder prompt between arms is exactly that block.
- Cases (`cases/`, `labels.json`): three pairs, each the commit that introduced a labelled weak test (`bad`) and the later fix (`repaired`). Labels come from the PR bodies of the fixes (#135, #167, #115) and the legacy #249 audit. Pair 1 of the corpus (the Bats to bashunit migration) was excluded for size.
- 36 rounds on 2026-10-28: 2 arms × 6 changes × 3 repetitions, none degraded. Claude weekly quota 20% → 24%.
- Adjudication: one OpenCode gpt-5.6-terra agent per pair over all twelve rounds of the pair under opaque round ids (`adjudication/cross-arm/`, key included because the measurement is closed). A first pass with one adjudicator per arm (`adjudication/separate-*`) disagreed with itself on an identical finding; the cross-arm pass is the one scored.

## Results

Final-list hits on the nine bad rounds per arm, false positives on the nine repaired rounds:

| Pair | Category | baseline hits | candidate hits | baseline FP | candidate FP |
| --- | --- | ---: | ---: | ---: | ---: |
| 2 | regression-insensitive | 2 of 3 | 3 of 3 | 0 | 0 |
| 3 | implementation-coupling | 0 of 3 | 0 of 3 | 0 | 3 |
| 4 | reimplemented-production-logic | 0 of 3 | 0 of 3 | 0 | 0 |

The candidate's three false positives are one minor finding, raised by `docs+tests` in every repaired round of pair 3 and kept to the final list every time, that follows the block's wording against a correct repair. Pair 4 is the defect the block's first bullet describes, and no finder in either arm named it.

## Files

`metrics.json` (per pair per arm, both adjudication passes, per-round verdicts, cost), `verdict.json` (the report prose), `labels.json`, `cases/`, `driver.sh`, `collect.py`, `score.py`, `metrics.py`, `report.py`, `adjudication/`. Raw archives stay on the machine under `~/.local/state/revmux-bench/249-{baseline,candidate}`.
