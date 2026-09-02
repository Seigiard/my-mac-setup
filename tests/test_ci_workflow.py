from pathlib import Path
import re
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
WORKFLOW = REPOSITORY / ".github" / "workflows" / "test-dotfiles.yml"


class TestDotfilesWorkflow(unittest.TestCase):
    def workflow_text(self):
        return WORKFLOW.read_text(encoding="utf-8")

    def job_names(self, text):
        jobs = re.search(r"^jobs:\n(?P<body>.*)\Z", text, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(jobs, "workflow must declare a jobs block")
        return re.findall(r"^  ([a-zA-Z0-9_-]+):\n", jobs.group("body"), re.MULTILINE)

    def job_block(self, text, job_name):
        pattern = r"^  %s:\n(?P<body>.*?)(?=^  [a-zA-Z0-9_-]+:\n|\Z)" % re.escape(job_name)
        match = re.search(pattern, text, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, "%s job is missing" % job_name)
        return match.group("body")

    def named_step_block(self, job, step_name):
        pattern = r"^      - name: %s\n(?P<body>.*?)(?=^      - name: |\Z)" % re.escape(step_name)
        match = re.search(pattern, job, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, "%s step is missing" % step_name)
        return match.group("body")

    def declared_triggers(self, text):
        block = re.search(r"^on:\n(?P<body>.*?)(?=^\S)", text, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(block, "workflow must declare an on: block")
        triggers = set(re.findall(r"^  ([a-zA-Z_]+):", block.group("body"), re.MULTILINE))
        self.assertTrue(triggers, "no triggers parsed from the on: block")
        return triggers

    def events_selected_by_condition(self, step, declared):
        """Events a step's `if:` condition selects, as a subset of the declared
        triggers. Assumes the condition is a positive membership test over
        `github.event_name` (any spelling: `==` chains, fromJSON lists), which
        every trigger-gated step in this workflow uses."""
        match = re.search(r"^        if: (?P<expr>.+)$", step, re.MULTILINE)
        self.assertIsNotNone(match, "step must be gated by an if: condition")
        expr = match.group("expr")
        self.assertIn("github.event_name", expr)
        # The positive-membership assumption cannot survive negation; reject
        # such conditions instead of silently misreading them as selections.
        self.assertNotIn(
            "!", expr, "negated condition breaks this parser's assumption: %s" % expr
        )
        selected = {
            event
            for event in declared
            if re.search(r"\b%s\b" % re.escape(event), expr)
        }
        self.assertTrue(selected, "condition selects none of the declared triggers: %s" % expr)
        return selected

    def step_value(self, step, key, indent="          "):
        match = re.search(r"^%s%s: (.+)$" % (indent, re.escape(key)), step, re.MULTILINE)
        self.assertIsNotNone(match, "step must set %s" % key)
        return match.group(1).strip()

    # Pinned event policy, independent of the workflow file: what each
    # trigger means for this repo, not what the workflow currently says.
    #
    # Ordinary (minimal-install, cache-restoring) events -- every push and PR
    # run. These fire on nearly every commit, so they restore prior downloads
    # to stay fast, and only install what tests resolve from brew.
    MINIMAL_EVENTS = frozenset({"push", "pull_request"})
    # Full-verification (cache-saving, no-restore) events -- the nightly
    # schedule and the manual workflow_dispatch escape hatch. These exist
    # specifically to prove the complete Brewfile still installs against
    # current upstream archives, so they must fetch fresh rather than reuse a
    # restored cache entry, and they seed the cache for the next ordinary run.
    FULL_VERIFICATION_EVENTS = frozenset({"schedule", "workflow_dispatch"})

    def test_cache_restore_and_save_triggers_partition_the_declared_set(self):
        # Full-Brewfile verification events must fetch from upstream (no
        # restore) but still seed the cache; only ordinary events may restore.
        text = self.workflow_text()
        declared = self.declared_triggers(text)

        expected_declared = self.MINIMAL_EVENTS | self.FULL_VERIFICATION_EVENTS
        self.assertEqual(
            declared,
            expected_declared,
            "workflow's declared triggers must equal the pinned event policy "
            "(minimal ∪ full-verification); a new trigger must be classified "
            "into one of the two sets above, not silently added to neither",
        )
        minimal_events = self.MINIMAL_EVENTS

        for job_name in ("test-ubuntu", "test-macos"):
            with self.subTest(job=job_name):
                job = self.job_block(text, job_name)
                restore = self.named_step_block(job, "Restore Homebrew downloads cache")
                save = self.named_step_block(job, "Save Homebrew downloads cache")

                restore_events = self.events_selected_by_condition(restore, declared)
                save_events = self.events_selected_by_condition(save, declared)

                self.assertEqual(
                    restore_events,
                    minimal_events,
                    "only ordinary minimal-install events may restore old downloads",
                )
                self.assertEqual(
                    save_events,
                    self.FULL_VERIFICATION_EVENTS,
                    "every full-verification event must save fresh downloads",
                )

                # A save step that can also restore would let scheduled runs
                # pull an old archive and mask upstream fetch decay.
                restore_uses = self.step_value(restore, "uses", indent="        ")
                save_uses = self.step_value(save, "uses", indent="        ")
                self.assertIn("/save", save_uses)
                self.assertNotIn("/save", restore_uses)

                # A saved entry no restore-keys prefix can find is dead weight.
                # The per-OS path fragment is Homebrew's own contract: a
                # swapped or invented path warms nothing.
                restore_path = self.step_value(restore, "path")
                self.assertEqual(restore_path, self.step_value(save, "path"))
                expected_fragment = {
                    "test-ubuntu": ".cache/Homebrew",
                    "test-macos": "Library/Caches/Homebrew",
                }[job_name]
                self.assertIn(expected_fragment, restore_path)
                save_key = self.step_value(save, "key")
                restore_keys_block = re.search(
                    r"^          restore-keys: \|\n(?P<keys>(?:^            .+\n?)+)",
                    restore,
                    re.MULTILINE,
                )
                self.assertIsNotNone(restore_keys_block, "restore step must declare restore-keys")
                prefixes = [
                    line.strip()
                    for line in restore_keys_block.group("keys").splitlines()
                    if line.strip()
                ]
                self.assertTrue(
                    any(save_key.startswith(prefix) for prefix in prefixes),
                    "no restore-keys prefix can find the key the save step writes: %s" % save_key,
                )

    def test_every_job_declares_a_timeout(self):
        # Presence only — ceiling values are owned by issue 2026-08-21-008.
        # A job without a timeout burns the 360-minute default when it hangs.
        text = self.workflow_text()
        names = self.job_names(text)
        self.assertGreaterEqual(len(names), 3, "job parser found fewer jobs than the workflow runs")
        for name in names:
            with self.subTest(job=name):
                self.assertRegex(
                    self.job_block(text, name),
                    r"(?m)^    timeout-minutes: \d+",
                    "%s job must declare timeout-minutes" % name,
                )


if __name__ == "__main__":
    unittest.main()
