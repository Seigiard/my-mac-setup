from pathlib import Path
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
MAKEFILE = REPOSITORY / "Makefile"
WORKFLOW = REPOSITORY / ".github" / "workflows" / "test-dotfiles.yml"
COMPOSE = REPOSITORY / "docker" / "docker-compose.yml"
RUNNER = REPOSITORY / "tests" / "run-post-apply.sh"


class TestPostApplySuiteContract(unittest.TestCase):
    def test_post_apply_suite_uses_one_wrapper_with_two_explicit_modes(self):
        makefile = MAKEFILE.read_text(encoding="utf-8")
        workflow = WORKFLOW.read_text(encoding="utf-8")
        compose = COMPOSE.read_text(encoding="utf-8")

        self.assertEqual(
            workflow.count("run: tests/run-post-apply.sh full"),
            2,
            "both GitHub Actions post-apply steps must call the shared full-suite wrapper",
        )
        self.assertEqual(
            compose.count("tests/run-post-apply.sh full"),
            2,
            "both Docker full-suite services must call the shared full-suite wrapper",
        )
        self.assertEqual(
            makefile.count("tests/run-post-apply.sh host-safe"),
            1,
            "make test-suite must call the host-safe wrapper mode exactly once",
        )

        if not RUNNER.exists():
            self.fail("tests/run-post-apply.sh must own the post-apply bats command")

        runner = RUNNER.read_text(encoding="utf-8")
        self.assertIn(
            'exec bats --jobs 8 --no-parallelize-across-files "$@"',
            runner,
            "the wrapper must own the parallel bats flags so callers cannot drift",
        )
        self.assertIn("tests/idempotent.bats", runner)


if __name__ == "__main__":
    unittest.main()
