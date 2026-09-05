from pathlib import Path
import os
import re
import subprocess
import tempfile
import textwrap
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

    def events_selected_by_expression(self, expr, declared, context):
        """Events an arbitrary workflow expression selects, as a subset of
        the declared triggers. Assumes the expression is a positive
        membership test over `github.event_name` (any spelling: `==`
        chains, fromJSON lists) -- true of every trigger-gated step `if:`
        condition and of the MMS_CI_MINIMAL env expression in this
        workflow. The positive-membership assumption cannot survive
        negation (e.g. `!=`); reject such expressions instead of silently
        misreading a negated condition as selecting the events it names."""
        self.assertIn("github.event_name", expr, "%s must reference github.event_name" % context)
        self.assertNotIn(
            "!", expr, "negated %s breaks this parser's assumption: %s" % (context, expr)
        )
        selected = {
            event
            for event in declared
            if re.search(r"\b%s\b" % re.escape(event), expr)
        }
        self.assertTrue(selected, "%s selects none of the declared triggers: %s" % (context, expr))
        return selected

    def events_selected_by_condition(self, step, declared):
        """Events a step's `if:` condition selects -- see
        events_selected_by_expression for the shared parsing assumption."""
        match = re.search(r"^        if: (?P<expr>.+)$", step, re.MULTILINE)
        self.assertIsNotNone(match, "step must be gated by an if: condition")
        return self.events_selected_by_expression(match.group("expr"), declared, "condition")

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

    def test_mms_ci_minimal_selects_exactly_the_minimal_events(self):
        # MMS_CI_MINIMAL decides whether a run installs the full Brewfile or
        # only what tests resolve from brew. The consumer side (rendering
        # under MMS_CI_MINIMAL=1) is covered by templates_test.sh and
        # scripts_test.sh; this is the only coverage of WHICH CI events set
        # it. Compared against the pinned policy (an independent oracle from
        # the workflow file) so a full-verification event silently gaining
        # the minimal install -- or an ordinary event losing it -- fails
        # here instead of only showing up as installed-package drift.
        text = self.workflow_text()
        declared = self.declared_triggers(text)
        minimal_line = re.search(r"^  MMS_CI_MINIMAL: (?P<expr>.+)$", text, re.MULTILINE)
        self.assertIsNotNone(minimal_line, "workflow must declare MMS_CI_MINIMAL")
        expr = minimal_line.group("expr")
        selected = self.events_selected_by_expression(expr, declared, "MMS_CI_MINIMAL")
        self.assertEqual(
            selected,
            self.MINIMAL_EVENTS,
            "MMS_CI_MINIMAL must select exactly the pinned minimal-install "
            "events, and no full-verification event: %s" % expr,
        )

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

    def gate_script(self, text, job_name):
        """The shell body of the Brewfile-diff gate, ready to execute."""
        step = self.named_step_block(
            self.job_block(text, job_name),
            "Install the full Brewfiles when the diff touches one",
        )
        match = re.search(r"^        run: \|\n(?P<body>(?:^ {10}.*\n|^\n)+)", step, re.MULTILINE)
        self.assertIsNotNone(match, "gate step must declare a literal run: block")
        return textwrap.dedent(match.group("body"))

    def git_environment(self, home):
        """A git environment that cannot read the developer's own config."""
        environment = dict(os.environ)
        environment.update(
            HOME=str(home),
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_CONFIG_SYSTEM=os.devnull,
            GIT_AUTHOR_NAME="Gate Test",
            GIT_AUTHOR_EMAIL="gate@example.com",
            GIT_COMMITTER_NAME="Gate Test",
            GIT_COMMITTER_EMAIL="gate@example.com",
        )
        return environment

    def build_pull_request_checkout(self, root, pr_touches_brewfile):
        """A checkout shaped like actions/checkout on a `pull_request` event:
        HEAD is the merge of the PR head with a main tip that has moved on.
        Main's newer commit edits a Brewfile; the PR's own commit edits one
        only when asked. Returns (base_sha, head_sha)."""
        repository = root / "repo"
        repository.mkdir()
        brewfile = repository / "home" / "private_dot_config" / "brewfiles"
        brewfile.mkdir(parents=True)
        environment = self.git_environment(root)

        def git(*arguments):
            return subprocess.run(
                ("git",) + arguments,
                cwd=repository,
                env=environment,
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()

        def commit(path, contents, message):
            path.write_text(contents, encoding="utf-8")
            git("add", "-A")
            git("commit", "-q", "-m", message)
            return git("rev-parse", "HEAD")

        git("init", "-q")
        base = commit(brewfile / "Brewfile", 'brew "git"\n', "base")
        git("branch", "feature")
        main_tip = commit(brewfile / "Brewfile", 'brew "git"\nbrew "imagemagick"\n', "main edits a Brewfile")

        git("checkout", "-q", "feature")
        if pr_touches_brewfile:
            # A different file under brewfiles/ than main edited, so the merge
            # stays clean and the fixture tests the gate, not conflict handling.
            head = commit(
                brewfile / "Brewfile.macos", 'cask "ghostty"\n', "the PR edits a Brewfile"
            )
        else:
            head = commit(repository / "README.md", "unrelated\n", "the PR edits nothing under brewfiles")

        # The merge commit actions/checkout leaves in the working tree.
        git("checkout", "-q", "--detach", main_tip)
        git("merge", "-q", "--no-ff", "-m", "merge", head)
        return repository, base, head

    def run_gate(self, script, repository, event_name, base_sha, head_sha):
        """The gate's decision: (selects_full_install, stdout)."""
        github_env = repository.parent / "github_env"
        github_env.write_text("", encoding="utf-8")
        environment = self.git_environment(repository.parent)
        environment.update(
            GITHUB_EVENT_NAME=event_name,
            GITHUB_ENV=str(github_env),
            BASE_SHA=base_sha,
            HEAD_SHA=head_sha,
        )
        result = subprocess.run(
            ["bash", "-e", "-c", script],
            cwd=repository,
            env=environment,
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            result.returncode,
            0,
            "gate script failed: %s%s" % (result.stdout, result.stderr),
        )
        return "MMS_CI_MINIMAL=" in github_env.read_text(encoding="utf-8"), result.stdout

    def test_gate_reads_the_pull_request_head_not_the_merge_commit(self):
        # On a `pull_request` run, HEAD is the merge of the PR head with the
        # current main, so a Brewfile commit merged into main after the PR's
        # recorded base sits inside a diff that ends at HEAD. That charged
        # every unrelated PR a full Brewfile install (~4.5 min per job) until
        # the base pointer advanced. The oracle is the synthetic history below,
        # not the workflow text: only the PR's own commits may decide this.
        text = self.workflow_text()
        for job_name in ("test-ubuntu", "test-macos"):
            with self.subTest(job=job_name):
                script = self.gate_script(text, job_name)
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    repository, base, head = self.build_pull_request_checkout(
                        root, pr_touches_brewfile=False
                    )
                    full, output = self.run_gate(
                        script, repository, "pull_request", base, head
                    )
                self.assertFalse(
                    full,
                    "a PR that touches no Brewfile must keep the minimal "
                    "install even when main has since edited one: %s" % output,
                )

    def test_gate_still_selects_the_full_install_for_a_brewfile_pull_request(self):
        # Control for the test above: the narrowed diff must not cost a
        # Brewfile-editing PR its only pre-merge install proof.
        text = self.workflow_text()
        for job_name in ("test-ubuntu", "test-macos"):
            with self.subTest(job=job_name):
                script = self.gate_script(text, job_name)
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    repository, base, head = self.build_pull_request_checkout(
                        root, pr_touches_brewfile=True
                    )
                    full, output = self.run_gate(
                        script, repository, "pull_request", base, head
                    )
                self.assertTrue(
                    full,
                    "a PR that edits a Brewfile must install the full set: %s" % output,
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
