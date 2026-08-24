from pathlib import Path
import re
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
MAKEFILE = REPOSITORY / "Makefile"
COMPOSE = REPOSITORY / "docker" / "docker-compose.yml"


class TestDockerContract(unittest.TestCase):
    def test_make_test_ubuntu_uses_clearly_named_full_apply_service(self):
        makefile = MAKEFILE.read_text(encoding="utf-8")
        compose = COMPOSE.read_text(encoding="utf-8")

        target = re.search(r"^test-ubuntu:.*\n\t(?P<command>[^\n]+)", makefile, re.MULTILINE)
        self.assertIsNotNone(target, "Makefile must define the test-ubuntu target")
        self.assertIn(
            "docker compose -f docker/docker-compose.yml run --rm test-ubuntu",
            target.group("command"),
            "make test-ubuntu must not route through a misleading service name",
        )

        self.assertRegex(compose, r"(?m)^  test-ubuntu:\n", "docker-compose.yml must define the service make test-ubuntu runs")
        self.assertNotRegex(compose, r"(?m)^  test-quick:\n", "the full apply suite must not be named test-quick")
        self.assertIn("chezmoi apply --source=/home/testuser/.local/share/chezmoi --verbose", compose)
        self.assertIn("tests/idempotent.bats", compose)

    def test_full_services_stage_repository_issue_cli_for_smithers(self):
        compose = COMPOSE.read_text(encoding="utf-8")

        for service in ("test-full", "test-ubuntu"):
            match = re.search(
                rf"(?ms)^  {re.escape(service)}:\n(?P<body>.*?)(?=^  [a-z][a-z0-9-]*:\n|\Z)",
                compose,
            )
            self.assertIsNotNone(match, f"docker-compose.yml must define {service}")
            body = match.group("body")
            self.assertIn("- ../scripts:/home/testuser/scripts:ro", body)
            self.assertIn("- ../docs/issues:/home/testuser/issues:ro", body)
            self.assertIn(
                "cp -r /home/testuser/scripts /home/testuser/worktree/scripts",
                body,
            )
            self.assertIn(
                "cp -r /home/testuser/issues /home/testuser/worktree/docs/issues",
                body,
            )
            self.assertIn("mkdir -p /home/testuser/worktree/.git", body)


if __name__ == "__main__":
    unittest.main()
