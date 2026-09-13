import json
from pathlib import Path
import subprocess
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]


class ClientDiscoveryTests(unittest.TestCase):
    def test_clients_share_the_canonical_repository_issues_skill(self):
        skill = REPOSITORY / ".claude" / "skills" / "repository-issues" / "SKILL.md"
        self.assertTrue(skill.is_file())

        opencode_skill = REPOSITORY / ".opencode" / "skills" / "repository-issues"
        self.assertTrue(opencode_skill.is_symlink())
        self.assertFalse(Path(opencode_skill.readlink()).is_absolute())
        self.assertEqual(skill, opencode_skill.resolve() / "SKILL.md")

        pi_settings = REPOSITORY / ".pi" / "settings.json"
        self.assertEqual(
            {"skills": ["~/.claude/skills", "../.claude/skills"]},
            json.loads(pi_settings.read_text()),
        )

        agents = REPOSITORY / "AGENTS.md"
        self.assertTrue(agents.is_symlink())
        self.assertEqual(Path("CLAUDE.md"), agents.readlink())
        self.assertEqual((REPOSITORY / "CLAUDE.md").resolve(), agents.resolve())

    def check_ignore(self, path):
        return subprocess.run(
            ["git", "check-ignore", "-v", "--", path],
            cwd=REPOSITORY,
            text=True,
            capture_output=True,
            check=False,
        )

    def tracked_paths(self, path):
        result = subprocess.run(
            ["git", "ls-files", "--", path],
            cwd=REPOSITORY,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        return [line for line in result.stdout.splitlines() if line]

    def test_agent_client_directories_are_not_ignored(self):
        for client_dir in (".claude", ".opencode", ".pi"):
            with self.subTest(client=client_dir):
                not_ignored = self.check_ignore(client_dir)
                self.assertEqual(
                    1, not_ignored.returncode, not_ignored.stdout + not_ignored.stderr
                )
                self.assertNotEqual([], self.tracked_paths(client_dir))

                child_probe = client_dir + "/git-ignore-reachability-probe"
                child_not_ignored = self.check_ignore(child_probe)
                self.assertEqual(
                    1,
                    child_not_ignored.returncode,
                    child_not_ignored.stdout + child_not_ignored.stderr,
                )


if __name__ == "__main__":
    unittest.main()
