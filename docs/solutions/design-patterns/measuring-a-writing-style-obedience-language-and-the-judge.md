---
title: Measuring a writing style: obedience is not value, a metric set is a language filter, and the judge that failed was the protocol
date: 2026-09-08
category: design-patterns
module: writing-style
problem_type: design_pattern
component: testing_framework
severity: high
resolution_type: workflow_improvement
related_components:
  - measurement
  - agent_instructions
  - internationalization
applies_when:
  - "An always-loaded instruction file is being edited and the edit is about to ship on assertion rather than measurement"
  - "A regex metric set built for English is about to be applied to another language"
  - "An LLM judge is being built to decide which of two answers is better"
  - "A rule set is growing and the growth is being justified by the value of each individual rule"
symptoms:
  - "Every counted metric improves while the output reads worse"
  - "A non-English response scores clean because no metric applied to it"
  - "A judge puts every information-loss flag on the shorter answer"
  - "An always-loaded instruction file grows 23 percent across two commits with no measurement attached"
tags:
  - measurement
  - goodhart
  - internationalization
  - llm-judge
  - blind-rating
  - writing-style
---

# Measuring a writing style

`home/.chezmoitemplates/writing-style.md` is always loaded through four adapters,
so an edit to it changes every response the agent writes. No focused test owns
that behavior. Three lessons came out of building the harness that measures it.

## 1. A mechanical counter measures obedience, and obedience can invert against value

The counters are regexes: em-dashes, semicolons, contractions, filler words,
openers, closers. They answer one question — were the rules obeyed — and they
answer it well.

The skill whose counters this harness borrows audited its own 2.0.0 release and
found it had optimised against them
([`WHY-USELESS-2026-09-02.md`](https://raw.githubusercontent.com/aminblg/simpleenglish/d88aa463/evals/results/WHY-USELESS-2026-09-02.md)).
The metrics improved. The output got worse. The diagnosis was not that the rules
were wrong; it was rule dilution in always-loaded context.

**The remedy that worked was structural, not editorial.** The rebuild
([`rebuild-2026-09-02/RESULTS.md`](https://raw.githubusercontent.com/aminblg/simpleenglish/HEAD/evals/results/rebuild-2026-09-02/RESULTS.md))
did not select five good rules and delete the rest. It moved a 53-rule catalogue
out of the always-loaded file into an on-demand reference, leaving 1,825 tokens
in context. The rules survived; their residency changed.

That result is why the run header records each arm's token count. This
repository's own style file went from 2,796 to 3,437 proxy tokens across two
commits, always loaded, through three adapters. Whether that growth pays for
itself is exactly what the harness exists to ask, and the answer is not knowable
from reading the rules.

**Consequence for the design:** the mechanical section prints no verdict word.
Not pass, fail, better, worse, improved, or regression. It reports counts and
four statements about its own limits. A separate blind human leg answers the
reader-value question, and the two sections share no number, because a strong
mechanical delta must not be able to outvote a human verdict.

Within the mechanical leg, the useful split is **instructed** versus
**uninstructed**. A metric named by a rule that differs between the two arms is
instructed, and its movement is close to tautological: it confirms the model read
the rule. Uninstructed movement is the informative part.

## 2. A metric set silently becomes a language filter

The harness scores English and Russian. Porting the counters unchanged would have
produced a Russian report where nine of eleven regex checks were structurally
dead, every one of them reporting zero, and a zero reads as a clean response.
Every Russian answer would have looked obedient because nothing applied to it.

The em-dash is the sharper case. It is not merely inapplicable to Russian, it is
**wrong**. The dash is normative Russian punctuation: it stands in for an omitted
copula ("Пул — это набор соединений"), marks generalisation, and opens direct
speech. Counting it scores correct prose as defective, and the rule that
introduced the counter — "do not use an em-dash or a semicolon" — was written
against English and shipped to a bilingual reader without anyone noticing.

**The pattern:** every metric declares the languages it is valid for, and a
metric outside them is reported as "not measured for this language" with its
reason. Never as zero. Seven of fifteen metrics are gated for Russian, and the
report names all seven.

**The decline that made this affordable:** no Russian-specific counter was built.
Genitive noun chains are the one transferable defect, and Russian case endings
are ambiguous without morphology, so a regex would fire on ordinary prose and
there is no local corpus to calibrate against. The language is not unmeasured —
the human rater reads Russian — it is only not mechanically counted.

A second rule came out of the same investigation and is now in the style file
itself: an agent answering in Russian must translate the domain vocabulary too,
not carry English words across by morphology. A term the agent read in the source
minutes ago is not shared with the reader.

## 3. The judge that failed was the protocol, not the idea

Two generations of a pairwise LLM judge were built here and both were discarded.

- **Generation one** put 7 of 7 information-loss flags on the shorter answer.
- **Generation two** was told explicitly that length is not quality, and required
  a quoted sentence for every claimed omission. The longer answer still won 8 of
  9 non-tie pairs.

**This is unvalidated, not disproven.** Two controls were never run: no
swap-consistency gate, and no word-count restriction. The upstream judge that
produced a usable result — 14 of 16 for the shipped version — scored **every pair
in both orders** and kept only verdicts that survived the swap. Both generations
here drew one order per pair and never required a verdict to survive the swap.
That is the exact protocol difference, and it is the thing to fix before
concluding a judge cannot work here.

The replacement is a blind human leg: two responses labelled A and B, presentation
order drawn from a seed independent of the job-order seed, the mapping withheld
in a key file the rating interface never serves. Two fixed binary questions, no
numeric scale, eight pairs by default.

**Sample size is stated, not implied.** The report computes what the batch can
separate from chance: at eight one-sided verdicts only an 8-0 split reaches
p = 0.05, and 7-1 sits at 0.07 and is reported as suggestive. A 5-3 split is no
signal. A tally without that line invites reading noise as a result.

## What to reuse

- Report obedience and value as two legs that never combine into one score.
- Print a metric's inapplicability, never its structural zero.
- Check every borrowed metric against the languages it will actually meet.
- Before discarding a judge, check whether its protocol had a consistency gate.
- Record the always-loaded token count of any instruction file you measure.
