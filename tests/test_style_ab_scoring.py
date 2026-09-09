import importlib.machinery
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[1]
SCORE = REPOSITORY / "tests" / "style-ab" / "score.py"

# Two em-dashes each, and nothing else the counters look for. The Russian dash
# is normative punctuation here (omitted copula), which is the fact outside this
# repository that makes the gate a requirement rather than a restatement.
RUSSIAN = "Пул соединений — это набор готовых подключений. Открывать новое — дорого."
RUSSIAN_WORDS = 11  # counted by hand, not by the scorer
LATIN = "A connection pool — a set of open connections — is reused across requests."
LATIN_WORDS = 14  # counted by hand, not by the scorer

# The six metrics that need English morphology or an English word list. The
# em-dash is the seventh gated metric and is disabled for a different reason.
ENGLISH_ONLY = ("contractions", "present_perfect", "ing_after_comma",
                "filler", "opener", "closer")


def load_score_module():
    """Load the harness module by path.

    `tests/style-ab/` carries no `__init__.py`, so it is not importable and
    `unittest discover` never walks into it. Registration happens only after a
    successful exec, so a missing file reports as itself.
    """
    if "style_ab_score" in sys.modules:
        return sys.modules["style_ab_score"]
    loader = importlib.machinery.SourceFileLoader("style_ab_score", str(SCORE))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    sys.modules[loader.name] = module
    return module


def build_run(directory, responses, prompts=None):
    """Write the smallest run directory `score_run` accepts.

    `responses` maps a response filename stem to its text.
    """
    run_dir = Path(directory)
    (run_dir / "responses").mkdir(parents=True, exist_ok=True)
    (run_dir / "arms").mkdir(parents=True, exist_ok=True)
    (run_dir / "arms" / "baseline.md").write_text("Do not use a semicolon.\n")
    (run_dir / "arms" / "candidate.md").write_text(
        "Do not use a semicolon.\nDo not use an em-dash.\n")
    for stem, text in responses.items():
        (run_dir / "responses" / (stem + ".txt")).write_text(text)
    (run_dir / "manifest.json").write_text(json.dumps({
        "run_id": "fixture",
        "model": "sonnet",
        "arms": {
            "base": {"spec": "base", "sha256": "0" * 64, "tokens": 0, "commit": None},
            "baseline": {"spec": "HEAD", "sha256": "1" * 64, "tokens": 5, "commit": "abc"},
            "candidate": {"spec": "worktree", "sha256": "2" * 64, "tokens": 9, "commit": None},
        },
        "repeats": 1,
        "prompts": prompts or [],
    }))
    return run_dir


class TermUnderTestTest(unittest.TestCase):
    """The oracle is presence versus absence of the metric, not its value.

    Consumer: the reviewer reading `report.md` after a change to the translation
    rules.
    Observable failure: a prompt that declares no term under test reports zero
    untranslated occurrences, and zero reads as a perfect translation, so an
    untested prompt looks clean.
    """

    def setUp(self):
        self.score = load_score_module()

    def test_a_prompt_with_no_declared_term_reports_the_metric_as_not_measured(self):
        # #given a Russian answer to a prompt that names no term under test
        # #when it is scored
        record = self.score.score_response(RUSSIAN, "ru", term="")

        # #then the counter is absent rather than zero, because zero would read
        # as a translation that never had to happen
        self.assertNotIn("untranslated_term", record["metrics"])
        self.assertIn("untranslated_term", record["not_measured"])

    def test_a_declared_term_left_in_the_source_language_is_counted(self):
        # #given the control: the same shape of answer for a prompt that does
        # declare a term, with the term left untranslated twice
        answer = "Noise floor — это уровень фона. Считать noise floor надо до сравнения."

        # #when it is scored against that term
        record = self.score.score_response(answer, "ru", term="noise floor")

        # #then the counter runs, so absence in the case above is the gate and
        # not a counter that never worked. Case is ignored: a term at the start
        # of a sentence is capitalised by the language, not by the model.
        self.assertEqual(record["metrics"]["untranslated_term"], 2)
        self.assertNotIn("untranslated_term", record["not_measured"])

    def test_a_translated_answer_scores_zero_rather_than_being_absent(self):
        # #given an answer that carries the term only in Russian
        answer = "Уровень шума — это разброс при неизменных условиях."

        # #when it is scored against the declared term
        record = self.score.score_response(answer, "ru", term="noise floor")

        # #then zero is reported, and it means something here because the metric
        # applied: the term was under test and did not survive untranslated
        self.assertEqual(record["metrics"]["untranslated_term"], 0)

    def test_the_term_travels_from_the_manifest_to_the_report(self):
        # #given a run whose manifest declares the term for one prompt
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = build_run(
                tmp,
                {f"ru__q7-ru__{arm}__r1": "Noise floor и ещё раз noise floor."
                 for arm in ("base", "baseline", "candidate")},
                prompts=[{"prompt_id": "q7-ru", "language": "ru", "term": "noise floor"}],
            )

            # #when the run is scored
            scores = self.score.score_run(run_dir)
            record = [r for r in scores["responses"] if r["arm"] == "candidate"][0]

        # #then the scorer used the declared term rather than guessing one from
        # the prompt text, which carries several English words
        self.assertEqual(record["metrics"]["untranslated_term"], 2)


class LanguageRoutingTest(unittest.TestCase):
    """T3. The oracle is Russian orthography, which this repository does not own.

    Consumer: the reviewer reading `report.md`.
    Observable failure: a Cyrillic response is scored on English-morphology
    metrics and reads as clean, or its normative em-dashes are counted as
    defects and it reads as the worse arm for a reason no Russian reader would
    recognise.
    """

    def setUp(self):
        self.score = load_score_module()

    def test_a_cyrillic_response_reports_no_em_dash_count_at_all(self):
        # #given a Russian response whose two dashes are correct punctuation
        # #when it is scored
        record = self.score.score_response(RUSSIAN, "ru")

        # #then the counter is absent, not 2 and not 0: a zero would read as a
        # clean response and a 2 would read as two defects
        self.assertNotIn("em_dash", record["metrics"])
        self.assertIn("em_dash", record["not_measured"])

    def test_a_latin_response_does_report_its_em_dashes(self):
        # #given the control: the same two dashes in an English response
        # #when it is scored
        record = self.score.score_response(LATIN, "en")

        # #then the counter runs, so absence in the Russian case is the gate
        # rather than a counter that never worked
        self.assertEqual(record["metrics"]["em_dash"], 2)
        self.assertNotIn("em_dash", record["not_measured"])

    def test_english_morphology_metrics_are_absent_from_a_cyrillic_response(self):
        # #given a Russian response
        # #when it is scored
        record = self.score.score_response(RUSSIAN, "ru")

        # #then each English-only metric is named as not measured rather than
        # returning the structural zero that would read as obedience
        for metric in ENGLISH_ONLY:
            self.assertNotIn(metric, record["metrics"], metric)
            self.assertIn(metric, record["not_measured"], metric)

    def test_english_morphology_metrics_are_present_on_a_latin_response(self):
        # #given the control response, which triggers none of them
        # #when it is scored
        record = self.score.score_response(LATIN, "en")

        # #then each one is present with its count, so "absent" and "zero" are
        # two distinguishable states in the report
        for metric in ENGLISH_ONLY:
            self.assertIn(metric, record["metrics"], metric)
            self.assertNotIn(metric, record["not_measured"], metric)

    def test_length_metrics_survive_into_both_languages(self):
        # #given one response per script
        # #when both are scored
        russian = self.score.score_response(RUSSIAN, "ru")
        latin = self.score.score_response(LATIN, "en")

        # #then the word counts match a hand count, so a Russian response is
        # measured on something rather than on nothing
        self.assertEqual(russian["metrics"]["words"], RUSSIAN_WORDS)
        self.assertEqual(latin["metrics"]["words"], LATIN_WORDS)
        self.assertEqual(russian["metrics"]["sentences"], 2)

    def test_language_match_records_the_style_rule_it_measures(self):
        # #given a Russian prompt answered in Russian, and one answered in English
        # #when both are scored against the declared language
        matched = self.score.score_response(RUSSIAN, "ru")
        mismatched = self.score.score_response(LATIN, "ru")

        # #then the control separates them, because "match the reader's
        # language" is a rule of the style being measured
        self.assertEqual(matched["metrics"]["language_match"], 1)
        self.assertEqual(mismatched["metrics"]["language_match"], 0)

    def test_the_report_names_every_gated_metric_instead_of_omitting_it(self):
        # #given a run holding one Russian prompt across all three arms
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = build_run(tmp, {
                "ru__p1-ru__base__r1": RUSSIAN,
                "ru__p1-ru__baseline__r1": RUSSIAN,
                "ru__p1-ru__candidate__r1": RUSSIAN,
            })

            # #when the run is scored and rendered
            scores = self.score.score_run(run_dir)
            report = self.score.render_report(scores)

        # #then the reader is told the metric did not apply, rather than
        # reading a table with the row silently missing
        self.assertIn("not measured for this language", report)
        self.assertIn("em_dash", report)

    def test_a_metric_carries_its_own_denominator_when_a_reply_switches_script(self):
        # #given two Russian prompts, one answered in Russian and one in English,
        # which is the case `language_match` exists to catch
        with tempfile.TemporaryDirectory() as tmp:
            responses = {}
            for arm in ("base", "baseline", "candidate"):
                responses["ru__p1-ru__%s__r1" % arm] = RUSSIAN
                responses["ru__p2-ru__%s__r1" % arm] = LATIN
            run_dir = build_run(tmp, responses)

            # #when the run is scored
            scores = self.score.score_run(run_dir)
            block = scores["paired"]["ru"]

        # #then the block counts two prompts, but the em-dash row counts the one
        # prompt it actually applied to. Pooling it under two would state a
        # sample size that was never taken.
        self.assertEqual(block["prompt_count"], 2)
        self.assertEqual(block["metrics"]["em_dash"]["prompts"], 1)

        # #and the control: a metric valid for both languages keeps the full
        # denominator, so the smaller number is the gate and not an off-by-one
        self.assertEqual(block["metrics"]["words"]["prompts"], 2)

    def test_a_failed_control_arm_does_not_cost_the_prompt_its_pair(self):
        # #given a prompt whose compared pair is intact and whose empty control
        # arm produced nothing. The control feeds no pair: `run.py` compares
        # baseline against candidate and carries `base` as a reference only.
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = build_run(tmp, {
                "en__p1__baseline__r1": LATIN,
                "en__p1__candidate__r1": LATIN,
            })

            # #when the run is scored
            scores = self.score.score_run(run_dir)

        # #then the pair is still counted, because dropping it would shrink the
        # denominator over an arm that was never part of the comparison
        self.assertEqual(scores["paired"]["en"]["prompt_count"], 1)
        self.assertEqual(scores["excluded"], [])

        # #and the gap is still reported, so a silently absent control arm does
        # not pass as a complete run
        self.assertEqual(len(scores["control_incomplete"]), 1)
        self.assertIn("base", scores["control_incomplete"][0]["reason"])

    def test_an_arms_aggregate_cell_states_how_many_prompts_it_averaged(self):
        # #given a run where the control arm answered one prompt of two
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = build_run(tmp, {
                "en__p1__base__r1": LATIN,
                "en__p1__baseline__r1": LATIN,
                "en__p1__candidate__r1": LATIN,
                "en__p2__baseline__r1": LATIN,
                "en__p2__candidate__r1": LATIN,
            })

            # #when the run is scored and rendered
            scores = self.score.score_run(run_dir)
            report = self.score.render_report(scores)

        # #then the aggregate names each arm's own denominator, so three numbers
        # on one row are not read as averages over the same prompts
        table = scores["aggregate"]["en"]["prompt_counts"]
        self.assertEqual(table["base"], 1)
        self.assertEqual(table["baseline"], 2)
        self.assertIn("Prompts averaged", report)

    def test_a_prompt_missing_an_arm_leaves_the_paired_counts(self):
        # #given a run where the candidate arm produced no response
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = build_run(tmp, {
                "en__p1__base__r1": LATIN,
                "en__p1__baseline__r1": LATIN,
            })

            # #when the run is scored
            scores = self.score.score_run(run_dir)

        # #then the prompt is quarantined with its reason rather than scored on
        # the side that survived, which would hide the missing arm
        self.assertEqual(scores["paired"]["en"]["prompt_count"], 0)
        self.assertEqual(len(scores["excluded"]), 1)
        self.assertIn("candidate", scores["excluded"][0]["reason"])


if __name__ == "__main__":
    unittest.main()
