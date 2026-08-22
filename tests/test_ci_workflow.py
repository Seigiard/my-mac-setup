from pathlib import Path
import re
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
WORKFLOW = REPOSITORY / ".github" / "workflows" / "test-dotfiles.yml"


class TestDotfilesWorkflow(unittest.TestCase):
    def workflow_text(self):
        return WORKFLOW.read_text(encoding="utf-8")

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

    def test_full_brewfile_verification_does_not_restore_homebrew_downloads(self):
        text = self.workflow_text()
        expected = {
            "test-ubuntu": "~/.cache/Homebrew/downloads",
            "test-macos": "~/Library/Caches/Homebrew/downloads",
        }

        for job_name, cache_path in expected.items():
            with self.subTest(job=job_name):
                job = self.job_block(text, job_name)
                restore = self.named_step_block(job, "Restore Homebrew downloads cache")
                save = self.named_step_block(job, "Save Homebrew downloads cache")

                self.assertIn("uses: actions/cache@v4", restore)
                self.assertIn(
                    "if: ${{ github.event_name == 'push' || github.event_name == 'pull_request' }}",
                    restore,
                    "schedule and workflow_dispatch full-Brewfile runs must fetch from upstream, not restore old Homebrew downloads",
                )
                self.assertIn("path: %s" % cache_path, restore)
                self.assertIn("uses: actions/cache/save@v4", save)
                self.assertIn(
                    "if: ${{ github.event_name == 'schedule' || github.event_name == 'workflow_dispatch' }}",
                    save,
                    "full-Brewfile runs should save fresh upstream downloads only after the verification succeeds",
                )
                self.assertIn("path: %s" % cache_path, save)


if __name__ == "__main__":
    unittest.main()
