# Port source: the scratchpad A/B harness

This file preserves the inputs U1, U2 and U7 port from. The harness that produced
commit `0c5c33a`'s numbers ran from a session-scoped path under `/private/tmp`, which
does not survive the session. That is the same failure this plan exists to fix, one
level up, so the regexes and both judge rubrics are transcribed here verbatim.

Durable copy of the full tree, including all 72 generated responses: `~/style-ab-port-source-20260908/`.

## Provenance

| File | SHA-256 (first 16) | Role |
|---|---|---|
| `drive.py` | `9fc9f3ee6cabb556` | thread-pool driver, ported by U1 |
| `score.py` | `197e2f7f84421255` | regex counter, ported by U2 |
| `judge.py` | `ed406850df7d58b7` | first judge generation, NOT ported |
| `judge2.py` | `37c7fb1a2e68a243` | second judge generation, NOT ported |
| `prompts.tsv` | `98fa8c8257150cd3` | first task set, three prompts dropped |
| `prompts2.tsv` | `ce49ebcee7011fba` | second task set, all six kept |

## The thirteen metrics

`score.py` strips fenced blocks and inline code before counting, then reports:

```
em_dash, semicolon, present_perfect, ing_after_comma, contractions, filler, opener, closer, bold, headers, bullets, words, sentences
```

Counted from raw text rather than stripped prose: `bold`, `headers`, `bullets`.
`opener` and `closer` are 0/1 per response, not counts.

## The regexes, verbatim

```python
FENCE = re.compile(r"```.*?```", re.S)
INLINE = re.compile(r"`[^`\n]*`")
CONTRACTIONS = re.compile(r"\b(?:don|can|won|isn|aren|doesn|didn|wasn|weren|hasn|haven|couldn|wouldn|shouldn|ain)['’]t\b"
    r"|\b(?:it|that|there|here|what|who|he|she)['’]s\b"
    r"|\b(?:you|we|they)['’]re\b"
    r"|\b(?:i|you|we|they|it)['’](?:ll|ve|d)\b"
    r"|\blet['’]s\b|\bi['’]m\b",
    re.I,)
PRESENT_PERFECT = re.compile(r"\b(?:has|have|had)\s+(?:been|not\s+)?\w+ed\b", re.I)
ING_AFTER_COMMA = re.compile(r",\s+\w+ing\b", re.I)
FILLER = re.compile(r"\b(?:basically|simply|seamlessly|robust|powerful|comprehensive|leverage|leverages|leveraging|crucial)\b"
    r"|\bin order to\b|\bit is worth noting\b|\bit's worth noting\b",
    re.I,)
JUST = re.compile(r"\bjust\b", re.I)
OPENER = re.compile(r"^\s*(?:great question|certainly|sure[,!]|absolutely[,!]|let me\b|i'?ll\b|looking at your|to answer your)",
    re.I,)
CLOSER = re.compile(r"let me know if|hope (?:this|that) helps|happy to (?:clarify|help)|feel free to|anything else\?",
    re.I,)
BOLD = re.compile(r"\*\*[^*\n]+\*\*")
SENT = re.compile(r"[.!?](?:\s|$)")
```

Stripping, applied before the prose counters:

```python
FENCE = re.compile(r"```.*?```", re.S)
INLINE = re.compile(r"`[^`\n]*`")
```

## The five counters that are not named regexes

Four metrics are counted without a compiled pattern, and a transcript that omits them is
incomplete. Verbatim from `score.py`:

```python
"em_dash":   prose.count("—")
"semicolon": prose.count(";")
"headers":   sum(1 for l in lines if l.startswith("#"))
"bullets":   sum(1 for l in lines if re.match(r"\s*[-*+]\s", l))
"words":     len(prose.split())
```

`em_dash` is the counter R10 disables for Cyrillic responses. `headers` and `bullets` read
`raw.splitlines()`, not the code-stripped prose, so a heading inside a fenced block would
count; no response in the 72 preserved ones contains one, and U2 owns whether to change it.

## Judge rubric, first generation (not ported)

Discarded: 7 of 7 information-loss flags landed on the shorter answer.

```
You compare two answers written by an AI assistant for a working software engineer.

Judge on these, in order of weight:
1. Can the reader act on it? Is the answer in the first line, not after a warm-up?
2. Is every risk, precondition and caveat that one answer has also present in the other? Missing information is a serious defect.
3. Is the certainty honest? An answer that states a guess as fact is worse than one that hedges truthfully.
4. Is the prose clean? No filler, no decorative emphasis, no padding.

Return ONLY a JSON object, no prose around it:
{"winner": "A" | "B" | "tie",
 "reason": "<one sentence>",
 "info_loss": "A" | "B" | "none",
 "overconfident": "A" | "B" | "none",
 "telegraphic": "A" | "B" | "none"}

"info_loss" names the answer that omits a caveat, risk or precondition the other one has.
"overconfident" names the answer that states something as certain that the other correctly hedges.
"telegraphic" names the answer whose sentences are clipped to the point of being harder to read.
```

## Judge rubric, second generation (not ported)

Discarded: the longer answer still won 8 of 9 non-tie pairs despite the explicit
instruction below. Neither generation ran a swap-consistency gate or a word-count
restriction, which is the protocol difference from the upstream judge that worked.

```
You compare two answers a technical assistant wrote for the same question.

CRITICAL: length is not quality. Do NOT prefer an answer because it is longer, has more
sections, more bullets, or more examples. A shorter answer that carries the same information
is BETTER, not worse. Extra elaboration that the question did not ask for is a defect.

Count something as missing ONLY if it is a risk, precondition, caveat or correctness-critical
fact, AND you can quote the exact sentence from one answer that has no counterpart in the
other. An example, a diagram or a restatement is not a missing item.

Return ONLY this JSON, nothing else:
{"winner": "A" | "B" | "tie",
 "reason": "<one sentence, must not mention length or amount of detail>",
 "missing_from_A": ["<exact quote from B that A lacks>", ...],
 "missing_from_B": ["<exact quote from A that B lacks>", ...],
 "overconfident": "A" | "B" | "none",
 "telegraphic": "A" | "B" | "none"}

Leave the missing arrays empty when nothing qualifies.
```

## Invocation flags that must survive the port

```
claude -p <prompt> --model sonnet --allowed-tools "" \
  --settings '{"outputStyle":"default"}' \
  --append-system-prompt-file <variant>
```

`--settings` neutralises the operator's deployed output style, which would otherwise
leak into all three arms. `--allowed-tools ""` keeps the arms tool-free. The scratchpad
ran every job with its working directory inside the scratchpad, where no `CLAUDE.md`
exists; that was accidental and R6 makes it explicit.
