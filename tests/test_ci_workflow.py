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

    def test_cache_restore_and_save_triggers_partition_the_declared_set(self):
        # Full-Brewfile verification events must fetch from upstream (no
        # restore) but still seed the cache; only ordinary events may restore.
        text = self.workflow_text()
        declared = self.declared_triggers(text)

        # MMS_CI_MINIMAL defines which events are ordinary runs. Deriving the
        # restore set from it rejects a swap of the two conditions, which a
        # bare partition check would accept.
        minimal_line = re.search(r"^  MMS_CI_MINIMAL: (?P<expr>.+)$", text, re.MULTILINE)
        self.assertIsNotNone(minimal_line, "workflow must declare MMS_CI_MINIMAL")
        minimal_events = {
            event
            for event in declared
            if re.search(r"\b%s\b" % re.escape(event), minimal_line.group("expr"))
        }
        self.assertTrue(minimal_events, "no declared trigger selects the minimal install")

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
                    declared - minimal_events,
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

    def test_ubuntu_provisions_gitleaks_on_a_path_later_steps_resolve(self):
        # A gitleaks binary in a directory never appended to $GITHUB_PATH is
        # unresolvable for the Smithers gate.
        text = self.workflow_text()
        job = self.job_block(text, "test-ubuntu")
        install = self.named_step_block(job, "Install gitleaks")

        script = re.search(r"^        run: \|\n(?P<body>(?:^          .*\n?)*)", install, re.MULTILINE)
        self.assertIsNotNone(script, "Install gitleaks must be a multi-line run script")
        target = re.search(r"tar\s[^\n]*-C\s+\"?(?P<dir>[^\s\"]+)", script.group("body"))
        self.assertIsNotNone(target, "install script must extract into an explicit directory")

        gate_position = job.index("      - name: Run the Smithers test gate")
        path_appends = {
            append.group(1).strip()
            for append in re.finditer(r'echo\s+"?([^"\n]+?)"?\s*>>\s*"?\$GITHUB_PATH', job)
            # $GITHUB_PATH takes effect from the next step on, so an append
            # after the gate cannot make the scanner resolvable for it.
            if append.start() < gate_position
        }
        self.assertIn(
            target.group("dir"),
            path_appends,
            "gitleaks lands in a directory no step before the Smithers gate puts on $GITHUB_PATH",
        )

        self.assertNotIn(
            "brew install",
            install,
            "ordinary Ubuntu CI skips Linuxbrew, so the required scanner needs an independent install",
        )
        self.assertLess(
            job.index("      - name: Install gitleaks"),
            job.index("      - name: Run the Smithers test gate"),
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
