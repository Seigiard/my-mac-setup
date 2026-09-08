import importlib.machinery
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[1]
RATING = REPOSITORY / "tests" / "style-ab" / "rating.py"

# The vocabulary that names an arm. It belongs to `variants.py` and `run.py`,
# neither of which this change touches, which is what keeps it an oracle rather
# than a restatement of the blinding code.
ARM_WORDS = ("baseline", "candidate", "responses/", "__r1.txt")

PROMPTS = ["p1", "p2", "p3", "p4"]


def load_rating_module():
    if "style_ab_rating" in sys.modules:
        return sys.modules["style_ab_rating"]
    loader = importlib.machinery.SourceFileLoader("style_ab_rating", str(RATING))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    sys.modules[loader.name] = module
    return module


def build_run(directory):
    """A run directory with four prompts per language and three arms.

    Response texts name their arm nowhere: the arm is recoverable only through
    the key, which is the property the blinding depends on.
    """
    run_dir = Path(directory)
    (run_dir / "responses").mkdir(parents=True, exist_ok=True)
    (run_dir / "arms").mkdir(parents=True, exist_ok=True)
    (run_dir / "arms" / "baseline.md").write_text("Rule one.\n")
    (run_dir / "arms" / "candidate.md").write_text("Rule one.\nRule two.\n")
    texts = {"base": "Untouched text for", "baseline": "Alpha text for", "candidate": "Beta text for"}
    for language, suffix in (("en", ""), ("ru", "-ru")):
        for prompt in PROMPTS:
            for arm, prefix in texts.items():
                name = "%s__%s%s__%s__r1.txt" % (language, prompt, suffix, arm)
                (run_dir / "responses" / name).write_text("%s %s%s." % (prefix, prompt, suffix))
    (run_dir / "manifest.json").write_text(json.dumps({
        "run_id": "fixture", "model": "sonnet", "repeats": 1, "rating_seed": 4242,
        "arms": {"base": {}, "baseline": {}, "candidate": {}},
    }))
    return run_dir


class BlindingTest(unittest.TestCase):
    """T4. The oracle is the arm vocabulary, which this change does not define.

    Consumer: the rater.
    Observable failure: the rating page reveals which arm produced which
    response, so the verdicts are not blind and the reader-value leg is worthless.
    """

    def setUp(self):
        self.rating = load_rating_module()

    def prepared(self, run_dir, batch=8):
        return self.rating.prepare(run_dir, seed=4242, batch=batch)

    def test_no_served_payload_carries_an_arm_name_or_a_response_path(self):
        # #given a prepared rating session
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = build_run(tmp)
            payloads, _ = self.prepared(run_dir)

            # #when each payload is serialised exactly as the handler sends it
            for payload in payloads:
                served = json.dumps(payload, ensure_ascii=False)

                # #then nothing in those bytes names the arm behind either side
                for word in ARM_WORDS:
                    self.assertNotIn(word, served, f"{word!r} leaked into {payload['pair_id']}")

    def test_the_key_records_the_mapping_the_payload_withholds(self):
        # #given the same session
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = build_run(tmp)
            payloads, key = self.prepared(run_dir)

            # #when the key is read
            # #then it names an arm for each displayed position, so provenance
            # exists but lives outside anything the rater sees
            for payload in payloads:
                entry = key[payload["pair_id"]]
                self.assertEqual({entry["A"], entry["B"]}, {"baseline", "candidate"})

    def test_the_a_position_is_not_a_constant_function_of_the_arm(self):
        # #given a full batch
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = build_run(tmp)
            _, key = self.prepared(run_dir)

            # #when the arm shown first is collected across pairs
            first = {entry["A"] for entry in key.values()}

        # #then both arms appear first somewhere, so position carries no signal
        self.assertEqual(first, {"baseline", "candidate"})

    def test_the_displayed_text_is_the_text_the_key_claims(self):
        # #given a prepared session
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = build_run(tmp)
            payloads, key = self.prepared(run_dir)

            # #when each payload is compared against the response file the key names
            for payload in payloads:
                entry = key[payload["pair_id"]]
                for position in ("A", "B"):
                    name = "%s__%s__%s__r%s.txt" % (
                        entry["language"], entry["prompt_id"], entry[position], entry["repeat"])
                    expected = (run_dir / "responses" / name).read_text()

                    # #then they match, so the key is truthful and a blind
                    # verdict can still be resolved to an arm at report time
                    self.assertEqual(payload[position.lower()], expected)

    def test_the_unblinded_section_does_name_the_arms(self):
        # #given a session with one verdict recorded
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = build_run(tmp)
            payloads, key = self.prepared(run_dir)
            self.rating.write_key(run_dir, key)
            first = payloads[0]
            self.rating.record_verdict(run_dir, {
                "pair_id": first["pair_id"],
                "answers": {"faster": "A", "missing": "neither"},
                "note": "",
            }, rater="fixture")

            # #when the human section is rendered from the key and the verdicts
            section = self.rating.render_human_section(run_dir)

        # #then it does carry the arm names: the control proving the key is what
        # holds provenance and the payload is what withholds it
        self.assertIn("baseline", section)
        self.assertIn("candidate", section)

    def test_verdicts_given_under_two_wordings_are_never_added_together(self):
        # #given two pairs rated under two different question wordings, which is
        # what a reworded question produces in an already-started run
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = build_run(tmp)
            payloads, key = self.prepared(run_dir)
            self.rating.write_key(run_dir, key)
            rows = []
            for payload, wording in zip(payloads[:2], ("Old wording?", "New wording?")):
                self.rating.record_verdict(run_dir, {
                    "pair_id": payload["pair_id"],
                    "answers": {"faster": "A", "missing": "A"},
                    "note": "",
                }, rater="fixture")
                rows.append(wording)
            # Rewrite the two records so each carries its own wording and digest,
            # the way two rating sessions across a reword would leave them.
            path = run_dir / "ratings.jsonl"
            written = [json.loads(line) for line in path.read_text().splitlines()]
            for record, wording in zip(written, rows):
                record["questions"] = [record["questions"][0], wording]
                record["questions_sha256"] = wording  # a distinct digest per wording
            path.write_text("\n".join(json.dumps(r) for r in written) + "\n")

            # #when the human section is rendered
            section = self.rating.render_human_section(run_dir)

        # #then both wordings appear and the reader is warned, so two answers to
        # two different questions are never summed into one number
        self.assertIn("Old wording?", section)
        self.assertIn("New wording?", section)
        self.assertIn("never added together", section)

    def test_verdicts_under_one_wording_do_pool_into_one_tally(self):
        # #given the control: two pairs rated under the same wording
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = build_run(tmp)
            payloads, key = self.prepared(run_dir)
            self.rating.write_key(run_dir, key)
            for payload in payloads[:2]:
                self.rating.record_verdict(run_dir, {
                    "pair_id": payload["pair_id"],
                    "answers": {"faster": "A", "missing": "A"},
                    "note": "",
                }, rater="fixture")

            # #when the section is rendered
            section = self.rating.render_human_section(run_dir)

        # #then they are counted together and no warning fires, so the split
        # above is the reword and not a refusal to ever pool anything
        self.assertNotIn("never added together", section)
        self.assertEqual(section.count("Which response gets you to the next action"), 1)

    def test_a_rated_pair_is_not_offered_again(self):
        # #given one pair already rated
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = build_run(tmp)
            payloads, key = self.prepared(run_dir)
            self.rating.write_key(run_dir, key)
            self.rating.record_verdict(run_dir, {
                "pair_id": payloads[0]["pair_id"],
                "answers": {"faster": "B", "missing": "A"},
                "note": "",
            }, rater="fixture")

            # #when the session resumes
            remaining = self.rating.remaining(run_dir, payloads)

        # #then the rated pair is gone and the rest survive, so an interrupted
        # session is finished rather than restarted
        self.assertEqual(len(remaining), len(payloads) - 1)
        self.assertNotIn(payloads[0]["pair_id"], [p["pair_id"] for p in remaining])

    def test_the_batch_is_stratified_across_both_languages(self):
        # #given the default batch over a two-language run
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = build_run(tmp)
            payloads, key = self.prepared(run_dir, batch=4)

            # #when the sampled languages are collected
            languages = {key[p["pair_id"]]["language"] for p in payloads}

        # #then both are present, so a batch never measures one language only
        self.assertEqual(languages, {"en", "ru"})


if __name__ == "__main__":
    unittest.main()
