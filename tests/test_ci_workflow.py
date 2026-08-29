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
        # The real invariant behind the cache steps: full-Brewfile verification
        # events must fetch from upstream (no restore) but still seed the cache
        # (save), while ordinary events restore. So the restore-trigger set and
        # the save-trigger set must be disjoint and together cover every
        # declared trigger — read from the on: block, so a newly added trigger
        # that neither step accounts for turns this red.
        text = self.workflow_text()
        declared = self.declared_triggers(text)

        for job_name in ("test-ubuntu", "test-macos"):
            with self.subTest(job=job_name):
                job = self.job_block(text, job_name)
                restore = self.named_step_block(job, "Restore Homebrew downloads cache")
                save = self.named_step_block(job, "Save Homebrew downloads cache")

                restore_events = self.events_selected_by_condition(restore, declared)
                save_events = self.events_selected_by_condition(save, declared)

                self.assertEqual(
                    restore_events & save_events,
                    set(),
                    "an event must not both restore old downloads and save them back",
                )
                self.assertEqual(
                    restore_events | save_events,
                    declared,
                    "every declared trigger must be covered by exactly one cache step",
                )

                # The save-only step must use the save-only action variant, or
                # scheduled runs would restore an old archive and mask upstream
                # fetch decay; the restore step must not be save-only.
                restore_uses = self.step_value(restore, "uses", indent="        ")
                save_uses = self.step_value(save, "uses", indent="        ")
                self.assertIn("/save", save_uses)
                self.assertNotIn("/save", restore_uses)

                # Cache identity: the save step must write the path the restore
                # step reads, and the key it saves under must be findable by at
                # least one restore-keys prefix — otherwise saved entries are
                # dead weight.
                self.assertEqual(
                    self.step_value(restore, "path"),
                    self.step_value(save, "path"),
                )
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
        # The property behind the install step: the directory gitleaks is
        # extracted into must be one this job also appends to $GITHUB_PATH,
        # or the Smithers gate cannot resolve the scanner. Derived from the
        # scripts instead of mirroring the download URL or version pin.
        text = self.workflow_text()
        job = self.job_block(text, "test-ubuntu")
        install = self.named_step_block(job, "Install gitleaks")

        script = re.search(r"^        run: \|\n(?P<body>(?:^          .*\n?)*)", install, re.MULTILINE)
        self.assertIsNotNone(script, "Install gitleaks must be a multi-line run script")
        target = re.search(r"tar\s[^\n]*-C\s+\"?(?P<dir>[^\s\"]+)", script.group("body"))
        self.assertIsNotNone(target, "install script must extract into an explicit directory")

        path_appends = {
            entry.strip()
            for entry in re.findall(r'echo\s+"?([^"\n]+?)"?\s*>>\s*"?\$GITHUB_PATH', job)
        }
        self.assertIn(
            target.group("dir"),
            path_appends,
            "gitleaks lands in a directory the workflow never puts on $GITHUB_PATH",
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
        # Presence only; the ceiling values are owned by issue
        # 2026-08-21-008-revisit-ci-timeout-minutes-after-minimal-install.
        # Without a declared timeout a hung job burns the 360-minute default.
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
