---
title: Revmux benchmark report template
type: benchmark
date: 2026-10-27
topic: revmux-benchmark-report
status: template
---

# Revmux benchmark report

## Corpus and split

State the corpus revision, case count, and pilot, tuning, and holdout split.

## Models and versions

Record the exact model, provider, client, revmux version, profile, and repetition
count for each opaque arm. Keep the mapping private until adjudication closes.

## Per-case results

| Case | Arm | Repetition | Degraded | Found | Synthesized | Verified | Final |
| --- | --- | ---: | --- | ---: | ---: | ---: | ---: |
|  |  |  |  |  |  |  |  |

## Aggregates

Include the analyzer's per-case and per-arm stage tables. Include all finding
fates and vendor-set groups. Record `found_fates` (kept, dropped, merged) for
each round, plus degraded, unreadable, and verify-failed round counts.

## Adjudication method

Describe the blind process, semantic cause matching, recorded basis, and full
denominator. State how `baseline-only`, `candidate-only`, `shared`, and
`ambiguous` causes were handled.

## Limitations

Record archive degradation, unreachable cases, environment differences, and
any cases excluded before scoring.

## Recommendation

State only the recommendation supported by the adjudicated holdout results.
