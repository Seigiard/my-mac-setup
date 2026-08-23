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


if __name__ == "__main__":
    unittest.main()
