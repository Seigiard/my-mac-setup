---
title: Revmux holdout for #576, Terra against Sol
type: benchmark
date: 2026-10-29
topic: revmux-benchmark-holdout-576
status: closed, superseded by the production trial
---

# Revmux holdout for #576, Terra against Sol

The pre-registered holdout that issue #576 asked for: gpt-6.1-terra against gpt-6.1-sol on the Codex side of revmux, with the Claude side fixed as a live same-model control. The margin and the three gates were posted on the issue before the first round ([pre-registration](https://github.com/Seigiard/my-mac-setup/issues/576#issuecomment-6503874268)). Result under the declared gates: **not accepted**; gate 2 failed by one finding, and the five Terra majors that decided it are listed for the human pass. Full page: [report](https://reports.1218217.xyz/reports/my-mac-setup/20261029T215938Z-b888b45a/index.html), Russian version in ASD-STE100 style: [отчёт](https://reports.1218217.xyz/reports/my-mac-setup/20261029T215939Z-06545789/index.html). Both expire after 28 days; `report.py` and `report_ru.py` rebuild them from `metrics.json`, `verdict.json` and `verdict_ru.json`.

## Setup

- Arms: `bench-baseline` (opus 5.5 + gpt-6.1-sol) and `bench-terra` (opus 5.5 + gpt-6.1-terra), the profiles from PR #574, byte-identical to the checkout in the scratch config the pilot used (`~/.local/state/revmux-bench/408-pilot/config`, revmux 0.2.7). Eleven finders; synthesis and verification on opus:high in both.
- Cases: five, one per corpus repository, none of the three pilot cases, the `r249` cases kept out (`cases/`): `mms-pr-525`, `homelab-feat-8`, `ttrpg-pr-152`, `platform-prd-3672`, `ux-chain-prd-3567`.
- 30 rounds (2 arms × 5 cases × 3 repetitions) on 2026-10-29, 20:06 to 22:52, one at a time (`driver.sh`; `codex-quota.sh` is the Codex weekly probe it uses), none degraded, actual model equal to requested in every manifest. Claude weekly quota 45% → 50%, Codex 5% → 8%; no cap reached.
- Adjudication: blind packet from `export-blind` over the merged archive (`packet.json`, `analysis.json`); `split.py` builds one input per case with every major, every final-list finding and every fourth merged or dropped minor per round (42 of 209 minors); five OpenCode gpt-5.6-terra adjudicators, one per case (`adjudication/prompt-case-1.md` is the first prompt; the others differ only in case, repository and SHAs), wrote `adjudication/out/case-N.json`: 285 of 285 selected findings adjudicated. `join.py` opens the key and applies the gates.
- `key.json` maps the opaque round and finding codes to arms. It was added after the owner read the five majors: the owner counts a finding of the kind "this test does not check X" as valid when the change set out to cover X, which would overturn gate 2, and chose a one-week production trial of both models over re-adjudication (`../trial-terra/`).

## Results

| Gate (declared before the first round) | Measured | Result |
| --- | --- | --- |
| 1. Terra-only valid causes ≥ Sol-only − 3 | 7 Terra-only, 4 Sol-only, 8 shared | pass |
| 2. Terra invalid ≤ 0.5 per round, and ≤ 1 invalid Terra finding on a final list | 8 invalid in 15 rounds (0.53 per round); 1 on a final list | fail |
| 3. Opus-against-Opus control differs by ≤ 3 unique valid causes | 2 baseline-arm only, 3 Terra-arm only, 11 shared | ranked |

Terra raised 108 Codex-side findings against Sol's 56 over the same 15 rounds, 56 valid majors against 23, at 53% of Sol's Codex tokens and 4.7 minutes per round against 6.2. Sol had no invalid finding among 45 adjudicated; Terra had 8 among 84. Five of the 8 are majors and every one of them names a missing test or a test fixture; the adjudicator's basis throughout was a reproduced defect in the frozen code. The Opus side, identical in both arms, ran at 1.4 invalid per round in both. One overturned major in the human pass makes gate 2 pass.

## Files

`metrics.json` (per arm, per side, per gate, per finding with verdicts), `verdict.json` and `verdict_ru.json` (the report prose), `analysis.json`, `packet.json`, `cases/`, `adjudication/` (prompt, five inputs, five verdict files), and the scripts `driver.sh`, `codex-quota.sh`, `merge.py`, `split.py`, `prompts.py`, `adjudicate.sh`, `join.py`, `report.py`, `report_ru.py`. The raw archive stays on the machine under `~/.local/state/revmux-bench/576-holdout`.
