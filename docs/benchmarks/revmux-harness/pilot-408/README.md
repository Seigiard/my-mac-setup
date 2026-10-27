---
title: Revmux model pilot for #408
type: benchmark
date: 2026-10-28
topic: revmux-benchmark-pilot-408
status: pilot
---

# Revmux model pilot for #408

A pilot, not a holdout: it proves the chain from harness to blind adjudication and sizes the holdout. It decides neither hypothesis. Full page: [pilot report](https://reports.1218217.xyz/reports/my-mac-setup/20261027T225931Z-4c99b79c/index.html) (expires after 28 days; `report.py` rebuilds it from `metrics.json`).

## Setup

- Arms: `bench-baseline` (opus 5.5 + gpt-6.1-sol), `bench-sonnet` (every Claude agent on sonnet 5.5), `bench-terra` (every Codex agent on gpt-6.1-terra). Ten-agent `dual-model` roster plus the `prose` lens group, eleven finders; synthesis and verification on opus:high in every arm. Profiles live in `home/private_dot_config/revmux/prompts/profiles/`.
- Cases: `issue-509`, `prd-3488`, `r249-2` (`cases/`), frozen detached checkouts at the corpus SHAs.
- 27 rounds (3 arms × 3 cases × 3 repetitions) on 2026-10-27, none degraded or unreadable; actual model equal to requested in every manifest. The Claude weekly quota went from 15% to 19%.
- Blind packet from `export-blind` (`packet.json`); three adjudicators (OpenCode, gpt-5.6-terra, high), one per case, never saw `key.json`; 231 of 231 selected findings adjudicated (every major and every final-list finding; merged and dropped minors not adjudicated).

## Results

Valid causes per vendor side, nine rounds per arm, with same-model controls:

| Pair | first only | second only | shared |
| --- | ---: | ---: | ---: |
| Claude: opus (baseline) vs sonnet | 12 | 1 | 7 |
| Codex: sol (baseline) vs terra | 9 | 10 | 5 |
| control, Claude: opus vs opus (other arm) | 5 | 4 | 14 |
| control, Codex: sol vs sol (other arm) | 6 | 4 | 8 |

- Sonnet: not supported by the pilot. The Opus side raised 12 valid causes Sonnet never raised, against 1 the other way; the Opus-vs-Opus control is 5 against 4. Sonnet raised 0 valid majors against 17, at 50% of the Claude tokens.
- Terra: open. Sol and Terra raise sets of similar size with little overlap, and the Sol-vs-Sol control overlaps little too. Terra raised 27 valid majors against 9 and 4 invalid findings against 0, at 55% of Sol's Codex token count as the manifests count it.
- Noise: in the baseline arm only 11 of 28 valid causes appeared in all three repetitions of their case. Three repetitions per case is the minimum for the holdout.
- Pipeline: across 27 rounds one adjudicated-invalid finding reached a final list.

## Files

`metrics.json` (per arm, per pair, per finding with verdicts), `side_verdicts.json`, `analysis.json` (analyzer output), `packet.json` and `key.json`, `adjudication/` (prompt and the three verdict files), `cases/`, and the scripts `driver.sh`, `merge.py`, `join.py`, `report.py`. The raw archive stays on the machine at `~/.local/state/revmux-bench/408-pilot/archive`.
