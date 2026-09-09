# Style A/B harness

Measures what an edit to `home/.chezmoitemplates/writing-style.md` does to the
model's output. That file is always loaded, through four adapters, so a change
to it reaches every response the agent writes.

The harness has two legs and they are never combined.

| Leg | Asks | Answered by |
|---|---|---|
| Mechanical | Were the rules obeyed? | regex counters over the responses |
| Human | Did the answer get easier to use? | a blind pairwise rating session |

Obedience is not known to track reader value. The two legs have different sample
sizes and different error modes, so `report.md` keeps them in separate sections
that share no number. When they disagree, the human leg is the one about reader
value.

## Commands

Run the matrix, then score it, then rate it.

1. `make style-ab STYLE_AB_ARGS="--baseline <ref> --candidate worktree"`
2. `python3 tests/style-ab/score.py tests/style-ab/runs/<run id>`
3. `python3 tests/style-ab/run.py --rate tests/style-ab/runs/<run id>`
4. `python3 tests/style-ab/score.py tests/style-ab/runs/<run id>` again, to fold
   the verdicts into `report.md`

> **Warning:** step 1 spends API credits. Nothing in CI invokes it, and nothing
> depends on the `style-ab` target.

The defaults compare `HEAD` against the working tree, which measures nothing in a
branch whose style file is unchanged. Name both arms when that is the case.

Reproduce the measurement that produced commit `0c5c33a`:

```
python3 tests/style-ab/run.py --baseline 0c5c33a^ --candidate 0c5c33a --lang en
```

English only, on purpose: `0c5c33a` was measured on English prompts, and adding
a Russian half would not be a reproduction.

Take the noise floor:

```
python3 tests/style-ab/run.py --baseline HEAD --candidate HEAD --allow-identical --lang both
```

## Cost

Calls are `prompts × arms × repeats`, with eleven prompts per language and three
arms.

| Invocation | Calls |
|---|---|
| `--lang en --runs 1` | 33 |
| `--lang en --runs 2` (the historical reference run) | 66 |
| `--lang both --runs 1` | 66 |
| `--lang both --runs 2` (the default) | 132 |
| `--limit 2 --runs 1 --lang both` (a smoke check) | 12 |

Rating and scoring are free. `--rate` binds a loopback port and makes no network
call.

## What a run leaves behind

```
tests/style-ab/runs/<UTC timestamp>/
  arms/            the exact system-prompt bytes each arm injected
  responses/       one file per language, prompt, arm and repeat
  failures.jsonl   jobs that did not complete, with reasons
  manifest.json    the run header: model, hashes, seeds, flags
  scores.json      every count, per response and aggregated
  rating-key.json  which arm was shown as A; not served to the rater
  ratings.jsonl    one verdict per rated pair
  report.md        the rendered artifact
```

`tests/style-ab/runs/` is gitignored. Generated responses are never committed.

## Metric spec, version 1

Fenced code blocks are removed first, then inline code spans, before any prose
counter runs. `bold`, `headers` and `bullets` read the raw text instead, so a
heading inside a fenced block would count.

| Metric | Counts | Direction that means obedience | en | ru |
|---|---|---|---|---|
| `em_dash` | occurrences of `—` in prose | lower | valid | **disabled** |
| `semicolon` | occurrences of `;` in prose | lower | valid | valid, lower confidence |
| `present_perfect` | `\b(has\|have\|had)\s+(been\|not\s+)?\w+ed\b` | lower | valid | not measured |
| `ing_after_comma` | `,\s+\w+ing\b` | lower | valid | not measured |
| `contractions` | `don't`, `it's`, `you're`, `I'll`, `let's` and the rest of the list | lower | valid | not measured |
| `filler` | basically, simply, seamlessly, robust, powerful, comprehensive, leverage, crucial, "in order to", "it is worth noting" | lower | valid | not measured |
| `opener` | 0 or 1: the response starts with "great question", "certainly", "sure,", "let me", "I'll", "looking at your", "to answer your" | lower | valid | not measured |
| `closer` | 0 or 1: the response contains "let me know if", "hope this helps", "happy to clarify", "feel free to", "anything else?" | lower | valid | not measured |
| `bold` | `**...**` spans in raw text | none stated | valid | valid |
| `headers` | lines starting with `#` | none stated | valid | valid |
| `bullets` | lines starting with a bullet marker | none stated | valid | valid |
| `words` | whitespace-separated tokens in prose | none stated | valid | valid |
| `sentences` | `[.!?]` followed by whitespace or end | none stated | valid | valid |
| `mean_sentence_length` | `words / sentences` | none stated | valid | valid |
| `language_match` | 1 when the detected script matches the prompt's declared language | higher | valid | valid |
| `untranslated_term` | occurrences of the prompt's declared source-language term, case-insensitive | lower | valid | valid |

Seven metrics do not survive into Russian, and the report prints
"not measured for this language" with the reason for each. It never prints zero,
because a structural zero reads as a clean response and would let a Russian
answer look obedient when nothing applied to it.

The em-dash is the one metric that is disabled rather than merely inapplicable.
The dash is normative Russian punctuation: it stands in for an omitted copula
("Пул — это набор соединений"), marks generalisation, and opens direct speech.
Counting it would score correct prose as defective, and inverting it would score
a rule the style never states.

`language_match` measures the style's own "match the reader's language" rule.
Script detection is the language proxy: a response mixing English prose with an
isolated Cyrillic quotation routes to the Russian set, and `scores.json` records
the detected script per response so that case is visible.

## Reading the mechanical section

A metric is **instructed** when a rule that differs between the two arms names
it. `score.py` decides this by diffing the two arms' rule text, so it is a
property of the run rather than a fixed list.

- **Instructed movement confirms the model read the rule.** It is close to
  tautological. A run where the instructed metrics do not move is evidence the
  rule did not land; a run where they do move tells you nothing beyond that.
- **Uninstructed movement is the informative signal.** It is where a rule about
  em-dashes turns out to also change sentence count, or where nothing moves at
  all.

Counts are paired per prompt. Repeats of one prompt are correlated draws, so
they are averaged within the prompt before any direction is taken, and a count
reads "N of 11 prompts" rather than "N of 22 pairs".

A prompt leaves the paired counts when `baseline` or `candidate` is incomplete,
because scoring the surviving side would hide whatever happened on the missing
one, and failures follow long answers rather than falling at random. A gap in
the empty control arm is reported but costs the prompt nothing: the control
enters no pair. The aggregate table carries a `Prompts averaged` row so an arm
that answered fewer prompts is not read as an average over the same set.

The section prints no verdict word. It carries four statements about its own
limits, and they are not decoration:

- Mechanical counts measure rule obedience.
- Obedience is not known to track reader value.
- The Russian metric set is a strict subset of the English one.
- The human leg is a small-sample single-rater judgement.

The upstream skill this harness borrows its counters from audited its own
2.0.0 release and found the counters had been optimised against
([`WHY-USELESS-2026-09-02.md`](https://raw.githubusercontent.com/aminblg/simpleenglish/d88aa463/evals/results/WHY-USELESS-2026-09-02.md)):
the metrics improved while the output got worse, and the diagnosis was rule
dilution in always-loaded context. The rebuild that fixed it
([`rebuild-2026-09-02/RESULTS.md`](https://raw.githubusercontent.com/aminblg/simpleenglish/HEAD/evals/results/rebuild-2026-09-02/RESULTS.md))
did not select better rules. It moved a 53-rule catalogue out of the always-loaded
file into an on-demand reference, leaving 1,825 tokens. That is why the run
header records each arm's token count.

Identical headers do not make two runs comparable. Responses are sampled, so
only within-run paired deltas are trustworthy.

## The human leg

`run.py --rate <run dir>` serves one pair per screen on a loopback HTTP server.
The rater sees two responses labelled A and B and never learns which arm wrote
which.

Two fixed questions, no numeric scale:

1. "Which response gets you to the next action faster, with less re-reading?" —
   A / B / no difference.
2. "Which response contains something important that the other is missing?" —
   A / B / neither.

A names the better response in both questions, so the two tallies read the same
way and the rater never has to reverse the sign between them.

Keys `q` `w` `e` answer the first, `a` `s` `d` answer the second, and `enter`
submits. Each verdict is written as it is given, so an interrupted session
resumes rather than restarts.

A free-text note quotes the labels A and B as the rater saw them, so the report
prints the arm behind each label on the line above the note. The note itself is
never rewritten.

Provenance lives in `rating-key.json` alone. `prepare` draws the presentation
order from a seed independent of the job-order seed, hands the handler the
payloads and nothing else, and the key is read only at report time. A verdict
records displayed positions, never arm names.

The default batch is 8 pairs, about five minutes. The report computes what that
batch can separate from chance rather than quoting a fixed sentence: at 8
one-sided verdicts only an 8-0 split reaches p = 0.05, and 7-1 sits at 0.07 and
is reported as suggestive rather than separated. A 5-3 split is no signal.
`--all` rates every pair.

The rater is the repository owner and is a single rater, so no inter-rater
agreement figure exists. Every verdict records the rater and an ISO timestamp,
and the report warns when a run's verdicts span more than one date: one person on
two different days is not one instrument.

## There is no model judge

Two generations of a pairwise LLM judge were built and both were discarded. The
first put 7 of 7 information-loss flags on the shorter answer. The second was
told explicitly that length is not quality and required a quoted sentence for
every claimed omission, and the longer answer still won 8 of 9 non-tie pairs.

Neither generation is proof that a judge cannot work here. Neither ran a
swap-consistency gate, and neither restricted for word count. The upstream judge
that produced a usable result scored every pair in **both** orders and discarded
any pair whose verdict did not survive the swap; these two drew one order per
pair. The protocol failed, which is not the same as the idea failing. See
`docs/solutions/design-patterns/measuring-a-writing-style-obedience-language-and-the-judge.md`.

## Calibration: the A/A noise floor

With eleven prompts per language and a sampled model, several metrics drift in
one direction by chance every run. Without a null distribution a reviewer cannot
tell an eight-of-eleven result from noise.

Measured on 20260908, model `sonnet`, `claude` 2.1.236 (Claude Code), both arms resolved to the same bytes (sha256 `27d8ff593e6dd10b`), 11 prompts per language, 2 repeats, 132 calls.

**en** — 11 paired prompts, identical arms.

| Metric | Prompts | Lower | Higher | Unchanged |
|---|---|---|---|---|
| `em_dash` | 11 | 7 | 0 | 4 |
| `semicolon` | 11 | 4 | 2 | 5 |
| `present_perfect` | 11 | 1 | 0 | 10 |
| `ing_after_comma` | 11 | 3 | 2 | 6 |
| `contractions` | 11 | 2 | 5 | 4 |
| `filler` | 11 | 0 | 0 | 11 |
| `opener` | 11 | 0 | 0 | 11 |
| `closer` | 11 | 0 | 0 | 11 |
| `bold` | 11 | 6 | 3 | 2 |
| `headers` | 11 | 0 | 2 | 9 |
| `bullets` | 11 | 6 | 3 | 2 |
| `words` | 11 | 8 | 3 | 0 |
| `sentences` | 11 | 6 | 3 | 2 |
| `mean_sentence_length` | 11 | 6 | 5 | 0 |
| `language_match` | 11 | 0 | 0 | 11 |

**ru** — 11 paired prompts, identical arms.

| Metric | Prompts | Lower | Higher | Unchanged |
|---|---|---|---|---|
| `em_dash` | 1 ⚠ | 0 | 0 | 1 |
| `semicolon` | 11 | 1 | 1 | 9 |
| `present_perfect` | 1 ⚠ | 0 | 0 | 1 |
| `ing_after_comma` | 1 ⚠ | 0 | 0 | 1 |
| `contractions` | 1 ⚠ | 0 | 0 | 1 |
| `filler` | 1 ⚠ | 0 | 0 | 1 |
| `opener` | 1 ⚠ | 0 | 0 | 1 |
| `closer` | 1 ⚠ | 0 | 0 | 1 |
| `bold` | 11 | 5 | 5 | 1 |
| `headers` | 11 | 4 | 1 | 6 |
| `bullets` | 11 | 4 | 5 | 2 |
| `words` | 11 | 3 | 8 | 0 |
| `sentences` | 11 | 5 | 5 | 1 |
| `mean_sentence_length` | 11 | 3 | 8 | 0 |
| `language_match` | 11 | 0 | 1 | 10 |

**Read this before reading any candidate run.** With identical arms, `em_dash`
still moved lower in 7 of 11 English prompts and `words` in 8 of 11. Those are
not effects. They are what this design returns when nothing changed.

Two consequences.

- **A directional count near 7 or 8 of 11 is inside the floor.** A candidate run
  has to clear it before the movement is about the edit. The historical
  reference run's `em_dash` result, 9 of 11, clears it by one prompt.
- **A per-metric binomial test is not valid here.** A 7-0 split has a nominal
  two-sided p of 0.016, and one appeared with identical arms. The run computes 15
  metrics across 2 languages, so about 30 simultaneous comparisons, and a result
  at that nominal level is expected roughly once per run by chance alone. The
  floor above is the empirical null; use it instead of a p-value.

The Russian half of the table shows the mixed-script case the `Prompts` column
exists for. Three of 66 Russian-declared responses arrived in Latin script, so
the seven English-only metrics have a denominator of 1 rather than 11. Their rows
carry ⚠ and must not be read as Russian measurements.

**A/A human tally**, 8 pairs, one rater, one day, under the earlier wording of
the second question:

| Question | `baseline` | `candidate` | third option |
|---|---|---|---|
| Which response gets you to the next action faster? | 5 | 3 | 0 no difference |
| (earlier wording) Does either leave out something important? | 1 | 1 | 6 neither |

5-3 on identical arms is inside the range a fair coin produces, which is the
result an A/A run should give. It is the evidence that the blinding holds: the
rater did not systematically favour either position or either arm.

Those eight verdicts were given before the second question was reworded, so they
carry the older question hash. The report groups verdicts by wording and never
adds two wordings together, so a later session on this same run appears as its
own tally rather than being pooled into these numbers.

Re-record whenever the model or the prompt sets change.

## A translation rule cannot be read from the counters

The report for commit `f721793`, which added the acceptance test to the
translation rule, moved no mechanical metric on 13 Russian prompts. That is
structural: none of the fifteen counters looks at which word was chosen.

The evidence is a direct reading of the responses to the prompt that names an
English term. For `q7-ru`, which asks the model to explain "noise floor":

| Arm | Repeat 1 | Repeat 2 |
|---|---|---|
| no style file | English term 8, Russian term 1 | |
| before the rule | English 6, Russian 0 | English 6, Russian 1 |
| after the rule | English 1, Russian 7 | English 5, Russian 1 |

In the first repeat the change is unambiguous: the earlier arm never produced a
Russian term and the later one produced «уровень шума» seven times, which is the
term the rule now names. In the second repeat neither arm translated. One prompt
and two repeats, with the effect in one of them: the direction is right and the
sample separates from nothing.

`q8-ru`, which asks about "idempotency", is the control. Both arms used
«идемпотентность» nine to eleven times regardless of the rule, because a real
Russian term already exists and nothing needed fixing. A rule that pushed harder
on every term would have changed this cell too, and it did not.

**Consequence for the evidence gate.** A change to the language rules cannot be
verified by the mechanical leg. Reading the term the model chose is the
measurement, and the report must carry that reading rather than a table of
counters that were blind to it.

That counter now exists. `untranslated_term` counts the prompt's declared
source-language term in the response, case-insensitively, and lower is better.
The prompt set carries a fourth column naming that term, empty for most rows,
because a scorer cannot guess it: a prompt mentions Postgres, git and A/B beside
the one term that matters. The manifest snapshots the declaration, so scoring
never depends on a prompt file that changed after the run.

A prompt that declares no term reports the counter as "not measured for this
prompt", never as zero. Zero would read as a translation that never had to
happen.

## Prompt sets

`prompts/core-en.tsv` and `prompts/core-ru.tsv`, eleven rows each, with aligned
ids (`p1` / `p1-ru`) so the same task can be compared across languages. Every
prompt is self-contained: answerable with no repository, no file, and no prior
turn.

Three English prompts from the original set are not here. Each silently needed
repository context, so both styled arms answered by asking for it, and the
resulting length difference read as information loss that was not there.

Two Russian prompts have no English counterpart: `q7-ru` and `q8-ru` ask the
model to explain an English technical term to a Russian speaker. They exist
because the rest of the set never forces the model to produce Russian domain
vocabulary, so no run could exercise the translation rules at all. A report on a
translation rule taken without them measures nothing, which is what the run for
commit `7824183` demonstrated.

The Russian half is otherwise a translation of the English half rather than
independently authored. The benefit is that one task compares across languages; the cost is
that a translated task may not be what a Russian speaker would spontaneously ask.

Prompts are single-turn and context-free, while the agent's real output is mostly
repository-grounded and multi-turn. The measured surface is not representative of
production usage.
