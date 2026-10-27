---
title: Revmux benchmark harness adjudication protocol
type: benchmark
date: 2026-10-27
topic: revmux-benchmark-adjudication
status: draft
---

# Adjudication protocol

1. Give the adjudicator only the blind packet from `export-blind` as input. Keep
   arm identifiers opaque until adjudication closes: do not show the model,
   provider, or arm mapping. Open the sealed key only after sign-off.
2. Compare each finding with the frozen base and head. Record exactly one basis:
   `prior human verdict`, `reproduced defect`, `recorded mutation`, or `none yet`.
3. Keep the full denominator. Findings marked rejected, immaterial,
   pre-existing, or open-question remain in the measurement.
4. Match the same underlying cause semantically, not by title or finding ID.
   Record each cause in one of `baseline-only`, `candidate-only`, `shared`, or
   `ambiguous` groups. An ambiguous match is not silently dropped.
5. A verifier's `confirmed` field is review output, not independent truth. The
   adjudicator checks the frozen code and records the basis separately.

For every arm, case, and repetition, retain the case-level denominator and the
per-finding record. Reveal arm identities only after all adjudication records
are complete and signed off.
