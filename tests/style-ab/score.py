#!/usr/bin/env python3
"""Turn a run directory into `scores.json` and the mechanical half of `report.md`.

Pure text to counts. No network, no subprocess, no model.

Two things separate this from the scratchpad scorer it ports. First, every
metric declares the languages it is valid for, and a metric that does not apply
is reported as "not measured for this language" rather than as zero, because a
structural zero reads as a clean response. Second, the em-dash counter is
disabled for Cyrillic responses: the dash is normative Russian punctuation, so
counting it scores correct prose as defective.

The mechanical leg answers one question only: were the rules obeyed. It carries
no verdict word, because obedience is not known to track reader value. The human
leg, which is the one about reader value, lives in `rating.py`.

Usage:
  python3 tests/style-ab/score.py tests/style-ab/runs/<run id>
"""

import argparse
import json
import re
import sys
from pathlib import Path

SCORER_VERSION = 1

# Ported verbatim from the scratchpad scorer, transcribed in PORT-SOURCE.md.
# Upstream also compiled a bare `\bjust\b` pattern that was not among its
# thirteen reported metrics; it is deliberately not ported.
FENCE = re.compile(r"```.*?```", re.S)
INLINE = re.compile(r"`[^`\n]*`")
CONTRACTIONS = re.compile(
    r"\b(?:don|can|won|isn|aren|doesn|didn|wasn|weren|hasn|haven|couldn|wouldn|shouldn|ain)['’]t\b"
    r"|\b(?:it|that|there|here|what|who|he|she)['’]s\b"
    r"|\b(?:you|we|they)['’]re\b"
    r"|\b(?:i|you|we|they|it)['’](?:ll|ve|d)\b"
    r"|\blet['’]s\b|\bi['’]m\b",
    re.I,
)
PRESENT_PERFECT = re.compile(r"\b(?:has|have|had)\s+(?:been|not\s+)?\w+ed\b", re.I)
ING_AFTER_COMMA = re.compile(r",\s+\w+ing\b", re.I)
FILLER = re.compile(
    r"\b(?:basically|simply|seamlessly|robust|powerful|comprehensive|leverage|leverages|leveraging|crucial)\b"
    r"|\bin order to\b|\bit is worth noting\b|\bit's worth noting\b",
    re.I,
)
OPENER = re.compile(
    r"^\s*(?:great question|certainly|sure[,!]|absolutely[,!]|let me\b|i'?ll\b|looking at your|to answer your)",
    re.I,
)
CLOSER = re.compile(
    r"let me know if|hope (?:this|that) helps|happy to (?:clarify|help)|feel free to|anything else\?",
    re.I,
)
BOLD = re.compile(r"\*\*[^*\n]+\*\*")
SENT = re.compile(r"[.!?](?:\s|$)")
BULLET = re.compile(r"\s*[-*+]\s")

CYRILLIC = re.compile(r"[Ѐ-ӿ]")
LATIN = re.compile(r"[A-Za-z]")

RESPONSE_NAME = re.compile(r"^(?P<language>[a-z]+)__(?P<prompt_id>.+)__(?P<arm>[a-z]+)__r(?P<repeat>\d+)$")

SCRIPT_LANGUAGE = {"cyrillic": "ru", "latin": "en"}

# The two arms the paired counts compare. `base` is the empty control: it feeds
# no pair and exists only to show how far the style moves the model off its
# untouched defaults.
PAIR_ARMS = ("baseline", "candidate")

NOT_MEASURED = "not measured for this language"

# The statements R22 requires the mechanical section to carry, verbatim.
LIMITS = [
    "Mechanical counts measure rule obedience.",
    "Obedience is not known to track reader value.",
    "The Russian metric set is a strict subset of the English one.",
    "The human leg is a small-sample single-rater judgement.",
]
DEFAULT_HUMAN_SECTION = """## Human leg

Not rated yet. Run `python3 tests/style-ab/run.py --rate <run dir>`.

The two legs share no number and are never combined. When they disagree, the
human leg is the one about reader value and the counters are about rule
obedience.
"""

COMPARABILITY = (
    "Identical headers do not make two runs comparable. Responses are sampled, "
    "so only within-run paired deltas are trustworthy."
)


def strip_code(raw):
    """Remove fenced blocks, then inline spans, before any prose counter runs."""
    return INLINE.sub(" ", FENCE.sub(" ", raw))


def detect_script(text):
    cyrillic = len(CYRILLIC.findall(text))
    latin = len(LATIN.findall(text))
    if cyrillic == 0 and latin == 0:
        return "unknown"
    return "cyrillic" if cyrillic > latin else "latin"


class Metric:
    """One counter plus the languages it is valid for.

    `reason` is printed wherever the metric is gated, so a reader never sees a
    blank cell without knowing why the number is missing.
    """

    def __init__(self, name, languages, count, reason=""):
        self.name = name
        self.languages = languages
        self.count = count
        self.reason = reason


# The validity table. Seven metrics do not survive into Russian: six because
# they need English morphology or an English word list, and the em-dash because
# counting it there would be wrong rather than merely uninformative.
METRICS = [
    Metric("em_dash", ("en",), lambda prose, raw: prose.count("—"),
           "Normative Russian punctuation: omitted copula, generalisation, direct speech."),
    Metric("semicolon", ("en", "ru"), lambda prose, raw: prose.count(";")),
    Metric("present_perfect", ("en",), lambda prose, raw: len(PRESENT_PERFECT.findall(prose)),
           "Russian has no perfect tense."),
    Metric("ing_after_comma", ("en",), lambda prose, raw: len(ING_AFTER_COMMA.findall(prose)),
           "The Russian analogue is the participial chain, which needs morphology."),
    Metric("contractions", ("en",), lambda prose, raw: len(CONTRACTIONS.findall(prose)),
           "No Russian surface."),
    Metric("filler", ("en",), lambda prose, raw: len(FILLER.findall(prose)),
           "English word list. A Russian list is buildable but uncalibrated."),
    Metric("opener", ("en",), lambda prose, raw: 1 if OPENER.search(prose) else 0,
           "English phrase patterns."),
    Metric("closer", ("en",), lambda prose, raw: 1 if CLOSER.search(prose) else 0,
           "English phrase patterns."),
    Metric("bold", ("en", "ru"), lambda prose, raw: len(BOLD.findall(raw))),
    Metric("headers", ("en", "ru"),
           lambda prose, raw: sum(1 for line in raw.splitlines() if line.startswith("#"))),
    Metric("bullets", ("en", "ru"),
           lambda prose, raw: sum(1 for line in raw.splitlines() if BULLET.match(line))),
    Metric("words", ("en", "ru"), lambda prose, raw: len(prose.split())),
    Metric("sentences", ("en", "ru"), lambda prose, raw: len(SENT.findall(prose))),
]

# Every metric name that maps to a rule the style states, with the strings that
# name that rule. A metric is "instructed" for a run when one of its strings
# appears on a line that differs between the two arms, which means the run is
# watching the model follow an instruction rather than reporting a side effect.
TRIGGERS = {
    "em_dash": ("em-dash", "—"),
    "semicolon": (";", "semicolon"),
    "present_perfect": ("present perfect", "has been", "have been", "has completed"),
    "ing_after_comma": (", making", "-ing"),
    "contractions": ("contraction", "n't"),
    "filler": ("filler", "basically", "simply", "in order to", "it is worth noting"),
    "opener": ("opener", "great question", "let me", "looking at your"),
    "closer": ("closer", "let me know if", "hope this helps", "feel free to"),
    "bold": ("bold",),
    "headers": ("header",),
    "bullets": ("bullet",),
    "words": ("shorten", "cut words", "delete"),
    "sentences": ("sentence",),
    "mean_sentence_length": ("sentence",),
    "language_match": ("language",),
}


def score_response(raw, declared_language):
    """Score one response against the metric set valid for its script.

    `declared_language` is what the prompt asked for. Detection routes the
    metrics; the two together produce `language_match`, which is the style's own
    "match the reader's language" rule measured rather than assumed.
    """
    prose = strip_code(raw)
    script = detect_script(prose)
    routed = SCRIPT_LANGUAGE.get(script, declared_language)

    metrics = {}
    not_measured = {}
    for metric in METRICS:
        if routed in metric.languages:
            metrics[metric.name] = metric.count(prose, raw)
        else:
            not_measured[metric.name] = metric.reason or NOT_MEASURED

    if metrics.get("sentences"):
        metrics["mean_sentence_length"] = round(metrics["words"] / metrics["sentences"], 2)
    else:
        metrics["mean_sentence_length"] = 0.0

    metrics["language_match"] = 1 if routed == declared_language else 0

    return {
        "declared_language": declared_language,
        "detected_script": script,
        "routed_language": routed,
        "metrics": metrics,
        "not_measured": not_measured,
    }


def changed_lines(baseline_text, candidate_text):
    """Lines present in exactly one of the two arms."""
    baseline = set(line.strip() for line in baseline_text.splitlines() if line.strip())
    candidate = set(line.strip() for line in candidate_text.splitlines() if line.strip())
    return baseline ^ candidate


def instructed_metrics(run_dir):
    """Metrics a rule that differs between the two arms names (R20)."""
    baseline = run_dir / "arms" / "baseline.md"
    candidate = run_dir / "arms" / "candidate.md"
    if not baseline.exists() or not candidate.exists():
        return set()
    diff = " \n ".join(changed_lines(baseline.read_text(), candidate.read_text())).lower()
    return {name for name, triggers in TRIGGERS.items()
            if any(trigger.lower() in diff for trigger in triggers)}


def read_responses(run_dir):
    records = []
    for path in sorted((run_dir / "responses").glob("*.txt")):
        match = RESPONSE_NAME.match(path.stem)
        if not match:
            raise SystemExit(f"{path}: filename does not name a language, prompt, arm and repeat")
        raw = path.read_text()
        record = score_response(raw, match.group("language"))
        record.update({
            "file": path.name,
            "prompt_id": match.group("prompt_id"),
            "arm": match.group("arm"),
            "repeat": int(match.group("repeat")),
            "empty": not raw.strip(),
        })
        records.append(record)
    return records


def mean(values):
    return sum(values) / len(values) if values else 0.0


def average_repeats(records, prompt_id, arm, metric_name):
    """Average a metric over one prompt's repeats before any direction is taken.

    Repeats of one prompt are correlated draws. Counting each repeat as its own
    pair would double the denominator without adding information (KTD6).
    """
    values = [r["metrics"][metric_name] for r in records
              if r["prompt_id"] == prompt_id and r["arm"] == arm
              and metric_name in r["metrics"]]
    return mean(values) if values else None


def partition_prompts(records, arms, repeats):
    """Split prompts by whether their compared pair is complete (R28).

    A prompt scored on the side that survived would hide whatever happened on
    the missing arm, so a prompt with a broken pair leaves the paired counts
    entirely and is reported with its reason. Failures are not random: they
    follow long and difficult answers, so keeping the surviving side would drop
    exactly the hard prompts from one arm.

    That reasoning covers the two arms being compared. A gap in the empty
    control arm is reported but costs the prompt nothing, because the control
    enters no pair and dropping the prompt would shrink the denominator over an
    arm the comparison never used.
    """
    complete = {}
    excluded = []
    control_incomplete = []
    control_arms = [arm for arm in arms if arm not in PAIR_ARMS]
    seen = {}
    for record in records:
        seen.setdefault((record["prompt_id"], record["declared_language"]), []).append(record)

    def gaps(group, wanted):
        missing = []
        for arm in wanted:
            for repeat in range(1, repeats + 1):
                present = [r for r in group
                           if r["arm"] == arm and r["repeat"] == repeat and not r["empty"]]
                if not present:
                    missing.append(f"{arm} r{repeat}")
        return missing

    for (prompt_id, language), group in sorted(seen.items()):
        pair_missing = gaps(group, [arm for arm in arms if arm in PAIR_ARMS])
        if pair_missing:
            excluded.append({
                "prompt_id": prompt_id,
                "language": language,
                "reason": "no usable response for " + ", ".join(pair_missing),
            })
            continue

        complete.setdefault(language, []).append(prompt_id)
        control_missing = gaps(group, control_arms)
        if control_missing:
            control_incomplete.append({
                "prompt_id": prompt_id,
                "language": language,
                "reason": "no usable response for " + ", ".join(control_missing),
            })
    return complete, excluded, control_incomplete


def paired_counts(records, complete, instructed):
    """Per language, count the direction of the baseline-to-candidate delta.

    The unit is the prompt, so a count reads "N of <prompt count> prompts".
    """
    result = {}
    for language, prompt_ids in sorted(complete.items()):
        in_language = [r for r in records if r["declared_language"] == language]
        metric_names = [m.name for m in METRICS] + ["mean_sentence_length", "language_match"]
        per_metric = {}
        for name in metric_names:
            rows = []
            for prompt_id in prompt_ids:
                baseline = average_repeats(in_language, prompt_id, "baseline", name)
                candidate = average_repeats(in_language, prompt_id, "candidate", name)
                if baseline is None or candidate is None:
                    continue
                rows.append((prompt_id, baseline, candidate))
            if not rows:
                per_metric[name] = {"measured": False, "reason": NOT_MEASURED}
                continue
            per_metric[name] = {
                "measured": True,
                # Its own denominator, not the block's. A metric gated for this
                # language still has rows when a response arrived in the other
                # script, and pooling those under the block's prompt count
                # states a sample size that was never taken.
                "prompts": len(rows),
                "instructed": name in instructed,
                "lower": sum(1 for _, b, c in rows if c < b),
                "higher": sum(1 for _, b, c in rows if c > b),
                "unchanged": sum(1 for _, b, c in rows if c == b),
                "baseline_mean": round(mean([b for _, b, _ in rows]), 2),
                "candidate_mean": round(mean([c for _, _, c in rows]), 2),
            }
        result[language] = {"prompt_count": len(prompt_ids), "metrics": per_metric}
    return result


def arm_means(records, complete):
    """Per language and arm, the mean of each measured metric over complete prompts."""
    result = {}
    for language, prompt_ids in sorted(complete.items()):
        in_language = [r for r in records if r["declared_language"] == language]
        arms = sorted({r["arm"] for r in in_language})
        table = {}
        # Each arm's own denominator. A control arm that lost a prompt averages
        # over fewer prompts than the compared pair, and three numbers on one
        # row must not read as averages over the same set.
        prompt_counts = {}
        for arm in arms:
            answered = [prompt_id for prompt_id in prompt_ids
                        if any(not r["empty"] for r in in_language
                               if r["prompt_id"] == prompt_id and r["arm"] == arm)]
            prompt_counts[arm] = len(answered)
        for name in [m.name for m in METRICS] + ["mean_sentence_length", "language_match"]:
            row = {}
            for arm in arms:
                values = [average_repeats(in_language, prompt_id, arm, name)
                          for prompt_id in prompt_ids]
                values = [v for v in values if v is not None]
                row[arm] = round(mean(values), 2) if values else None
            table[name] = row
        result[language] = {"arms": arms, "metrics": table, "prompt_counts": prompt_counts}
    return result


def load_json(path, default):
    return json.loads(path.read_text()) if path.exists() else default


def score_run(run_dir):
    run_dir = Path(run_dir)
    manifest = load_json(run_dir / "manifest.json", {})
    repeats = manifest.get("repeats", 1)
    records = read_responses(run_dir)

    # Arms come from the manifest, never from the files that happen to exist. An
    # arm that produced no response at all would otherwise drop out of the
    # expected set, and every prompt would look complete (KTD11).
    arms = sorted(manifest.get("arms") or {}) or ["base", "baseline", "candidate"]

    complete, excluded, control_incomplete = partition_prompts(records, arms, repeats)
    for language in {r["declared_language"] for r in records}:
        complete.setdefault(language, [])

    instructed = instructed_metrics(run_dir)
    failures = []
    failure_file = run_dir / "failures.jsonl"
    if failure_file.exists():
        failures = [json.loads(line) for line in failure_file.read_text().splitlines() if line.strip()]

    return {
        "scorer_version": SCORER_VERSION,
        "run_id": manifest.get("run_id", run_dir.name),
        "run_dir": str(run_dir),
        "manifest": manifest,
        "arms": arms,
        "instructed": sorted(instructed),
        "responses": records,
        "paired": paired_counts(records, complete, instructed),
        "aggregate": arm_means(records, complete),
        "excluded": excluded,
        "control_incomplete": control_incomplete,
        "failures": failures,
    }


def gated_reasons(records, language):
    """Which metrics were gated for this language, why, and on how many responses.

    The count matters when a response arrived in the other script: the metric
    then applied to part of the language's responses, and saying only "not
    measured" would contradict the row that carries its numbers.
    """
    in_language = [r for r in records if r["declared_language"] == language]
    reasons = {}
    for record in in_language:
        for name, reason in record["not_measured"].items():
            entry = reasons.setdefault(name, {"reason": reason, "gated": 0})
            entry["gated"] += 1
    for entry in reasons.values():
        entry["total"] = len(in_language)
    return reasons


def render_header(scores):
    manifest = scores["manifest"]
    lines = ["## Run header", "",
             "| Field | Value |", "|---|---|",
             f"| Run id | `{scores['run_id']}` |",
             f"| Model | `{manifest.get('model', 'unknown')}` |",
             f"| `claude` version | `{manifest.get('claude_version', 'unknown')}` |",
             f"| Repeats per prompt per arm | {manifest.get('repeats', 'unknown')} |",
             f"| Job order seed | {manifest.get('job_seed', 'unknown')} |",
             f"| Rating seed | {manifest.get('rating_seed', 'unknown')} |",
             f"| Job working directory | {manifest.get('job_cwd', 'unknown')} |",
             f"| Scorer version | {SCORER_VERSION} |"]
    for name, arm in manifest.get("arms", {}).items():
        commit = arm.get("commit") or "not a ref"
        lines.append(f"| Arm `{name}` | spec `{arm.get('spec')}`, sha256 "
                     f"`{arm.get('sha256', '')[:16]}`, commit `{commit}`, "
                     f"{arm.get('tokens')} tokens |")
    for prompt_set in manifest.get("prompt_sets", []):
        lines.append(f"| Prompt set | `{prompt_set.get('path')}` sha256 "
                     f"`{prompt_set.get('sha256', '')[:16]}` |")
    attestation = manifest.get("attestation", {})
    if attestation:
        lines.append(f"| Applied to every invocation | `--settings "
                     f"{attestation.get('settings_flag')}` and `--allowed-tools \"\"` |")
    lines.append(f"| Jobs that did not complete | {len(scores['failures'])} |")
    lines.append(f"| Prompts held out of the paired counts | {len(scores['excluded'])} |")
    lines.append("")
    return lines


def render_metric_rows(per_metric, names, prompt_count):
    rows = ["| Metric | Prompts | Candidate lower | Candidate higher | Unchanged | Baseline mean | Candidate mean |",
            "|---|---|---|---|---|---|---|"]
    for name in names:
        entry = per_metric[name]
        if not entry.get("measured"):
            rows.append(f"| `{name}` | 0 | {NOT_MEASURED} | | | | |")
            continue
        measured_on = entry.get("prompts", prompt_count)
        marker = "" if measured_on == prompt_count else " ⚠"
        rows.append(f"| `{name}` | {measured_on}{marker} | {entry['lower']} | {entry['higher']} | "
                    f"{entry['unchanged']} | {entry['baseline_mean']} | {entry['candidate_mean']} |")
    return rows


def render_report(scores, human_section=None):
    lines = [f"# Style A/B run `{scores['run_id']}`", ""]
    lines += render_header(scores)

    lines += ["## Mechanical leg", "",
              "This leg reports how often each counted feature moved between the two "
              "arms. It carries no verdict word, on purpose.", ""]
    for statement in LIMITS:
        lines.append(f"- {statement}")
    lines += ["", COMPARABILITY, "",
              "A metric is **instructed** when a rule that differs between the two arms "
              "names it. Instructed movement confirms the model read the rule. "
              "Uninstructed movement is the informative signal.", ""]

    for language, block in scores["paired"].items():
        prompt_count = block["prompt_count"]
        lines += [f"### {language} — {prompt_count} paired prompt(s)", ""]
        if prompt_count == 0:
            lines += ["No prompt in this language has every arm complete, so no "
                      "direction is counted.", ""]
        else:
            lines += [f"Counts below are out of {prompt_count} prompts. Repeats are "
                      "averaged within a prompt before any direction is taken. A "
                      "`Prompts` value below that total, marked ⚠, means the metric "
                      "applied to only that many prompts: a response arrived in the "
                      "other script and was routed to the other metric set.", ""]
            measured = [name for name, entry in block["metrics"].items() if entry.get("measured")]
            instructed = [name for name in measured if block["metrics"][name].get("instructed")]
            uninstructed = [name for name in measured if not block["metrics"][name].get("instructed")]
            if instructed:
                lines += ["**Instructed metrics.**", ""]
                lines += render_metric_rows(block["metrics"], instructed, prompt_count) + [""]
            if uninstructed:
                lines += ["**Uninstructed metrics.**", ""]
                lines += render_metric_rows(block["metrics"], uninstructed, prompt_count) + [""]

        reasons = gated_reasons(scores["responses"], language)
        if reasons:
            lines += [f"**Not measured for {language}.** Each of these is absent rather "
                      "than zero, so a response in this language can never read as clean "
                      "because nothing applied to it.", ""]
            for name, entry in sorted(reasons.items()):
                scope = ("" if entry["gated"] == entry["total"]
                         else f" on {entry['gated']} of {entry['total']} responses "
                              "(the rest arrived in the other script)")
                lines.append(f"- `{name}` — {NOT_MEASURED}{scope}. {entry['reason']}")
            lines.append("")

    lines += ["### Aggregate means", ""]
    for language, block in scores["aggregate"].items():
        arms = block["arms"]
        counts = block.get("prompt_counts", {})
        lines += [f"**{language}**", "",
                  "| Metric | " + " | ".join(f"`{arm}`" for arm in arms) + " |",
                  "|---|" + "---|" * len(arms),
                  "| Prompts averaged | "
                  + " | ".join(str(counts.get(arm, "?")) for arm in arms) + " |"]
        for name, row in block["metrics"].items():
            cells = []
            for arm in arms:
                value = row.get(arm)
                cells.append(NOT_MEASURED if value is None else str(value))
            lines.append(f"| `{name}` | " + " | ".join(cells) + " |")
        lines.append("")

    lines += ["### Held out of the counts", ""]
    control_gaps = scores.get("control_incomplete", [])
    if not scores["excluded"] and not scores["failures"] and not control_gaps:
        lines += ["Every prompt has every arm complete, and every job produced a response.", ""]
    for item in scores["excluded"]:
        lines.append(f"- prompt `{item['prompt_id']}` ({item['language']}) — {item['reason']}")
    for item in scores["failures"]:
        job = item.get("job", {})
        lines.append(f"- job `{job.get('language')}/{job.get('prompt_id')}/{job.get('arm')}"
                     f"/r{job.get('repeat')}` — {item.get('status')}: {item.get('reason')}")
    if scores["excluded"] or scores["failures"]:
        lines.append("")
    if control_gaps:
        lines += ["The control arm is incomplete on the prompts below. They stay in the "
                  "paired counts, because the control enters no pair. Their control "
                  "column above rests on fewer responses than the compared arms, and "
                  "the `Prompts averaged` row states each arm's own denominator.", ""]
        for item in control_gaps:
            lines.append(f"- prompt `{item['prompt_id']}` ({item['language']}) — {item['reason']}")
        lines.append("")

    lines += [human_section or DEFAULT_HUMAN_SECTION]
    return "\n".join(lines)


def human_section(run_dir):
    """Render the human leg when verdicts exist, otherwise say it is unrated.

    `rating.py` owns that leg. It is loaded by path only when there is something
    to render, so scoring never depends on it.
    """
    if not (Path(run_dir) / "ratings.jsonl").exists():
        return None
    import importlib.machinery
    import importlib.util
    path = Path(__file__).resolve().parent / "rating.py"
    loader = importlib.machinery.SourceFileLoader("style_ab_rating", str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module.render_human_section(run_dir)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("run_dir", help="a directory under tests/style-ab/runs/")
    args = parser.parse_args(argv)

    run_dir = Path(args.run_dir)
    if not (run_dir / "responses").is_dir():
        raise SystemExit(f"{run_dir}: no responses/ directory, so there is nothing to score")

    scores = score_run(run_dir)
    (run_dir / "scores.json").write_text(json.dumps(scores, indent=2, ensure_ascii=False))
    (run_dir / "report.md").write_text(render_report(scores, human_section(run_dir)))

    print(f"{run_dir / 'scores.json'}")
    print(f"{run_dir / 'report.md'}")
    for language, block in scores["paired"].items():
        print(f"  {language}: {block['prompt_count']} paired prompt(s)")
    if scores["excluded"]:
        print(f"  {len(scores['excluded'])} prompt(s) held out of the counts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
