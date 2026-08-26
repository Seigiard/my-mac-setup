from pathlib import Path
import re
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
MAKEFILE = REPOSITORY / "Makefile"
COMPOSE = REPOSITORY / "docker" / "docker-compose.yml"


class TestDockerContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.makefile = MAKEFILE.read_text(encoding="utf-8")
        cls.compose = COMPOSE.read_text(encoding="utf-8")

    def service_block(self, service_name):
        pattern = r"^  %s:\n(?P<body>.*?)(?=^  [a-zA-Z0-9_-]+:\n|^\S|\Z)" % re.escape(service_name)
        match = re.search(pattern, self.compose, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, "docker-compose.yml must define the %s service" % service_name)
        return match.group("body")

    def test_make_test_ubuntu_uses_clearly_named_full_apply_service(self):
        target = re.search(r"^test-ubuntu:.*\n\t(?P<command>[^\n]+)", self.makefile, re.MULTILINE)
        self.assertIsNotNone(target, "Makefile must define the test-ubuntu target")
        self.assertIn(
            "docker compose -f docker/docker-compose.yml run --rm test-ubuntu",
            target.group("command"),
            "make test-ubuntu must not route through a misleading service name",
        )

        self.assertRegex(self.compose, r"(?m)^  test-ubuntu:\n", "docker-compose.yml must define the service make test-ubuntu runs")
        self.assertNotRegex(self.compose, r"(?m)^  test-quick:\n", "the full apply suite must not be named test-quick")
        self.assertIn("chezmoi apply --source=/home/testuser/.local/share/chezmoi --verbose", self.compose)
        self.assertIn("tests/idempotent.bats", self.compose)

    def test_full_suite_services_stage_issue_cli_and_use_canonical_smithers_gate(self):
        required = [
            "../scripts/issues:/home/testuser/issues-cli:ro",
            "../docs/issues:/home/testuser/issues:ro",
            "../Makefile:/home/testuser/Makefile:ro",
            "mkdir -p /home/testuser/worktree/.git /home/testuser/worktree/docs /home/testuser/worktree/scripts",
            "cp /home/testuser/issues-cli /home/testuser/worktree/scripts/issues",
            "cp -r /home/testuser/issues /home/testuser/worktree/docs/issues",
            "cp /home/testuser/Makefile /home/testuser/worktree/Makefile",
            "make test-smithers",
        ]

        for service_name in ("test-full", "test-ubuntu"):
            with self.subTest(service=service_name):
                service = self.service_block(service_name)
                for contract_line in required:
                    self.assertIn(contract_line, service)

if __name__ == "__main__":
    unittest.main()
