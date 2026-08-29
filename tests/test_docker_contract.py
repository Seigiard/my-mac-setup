from pathlib import Path
import re
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
MAKEFILE = REPOSITORY / "Makefile"
COMPOSE = REPOSITORY / "docker" / "docker-compose.yml"


class TestDockerContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.makefile = MAKEFILE.read_text(encoding="utf-8")
        cls.compose = COMPOSE.read_text(encoding="utf-8")

    def service_names(self):
        names = re.findall(r"^  ([a-zA-Z0-9_-]+):\n", self.compose, re.MULTILINE)
        self.assertTrue(names, "no services parsed from docker-compose.yml")
        return names

    def service_block(self, service_name):
        pattern = r"^  %s:\n(?P<body>.*?)(?=^  [a-zA-Z0-9_-]+:\n|^\S|\Z)" % re.escape(service_name)
        match = re.search(pattern, self.compose, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, "docker-compose.yml must define the %s service" % service_name)
        return match.group("body")

    def service_command_script(self, service):
        match = re.search(
            r"^    command:\n      - \|\n(?P<script>(?:^        .*\n|^\n)*)",
            service,
            re.MULTILINE,
        )
        if match is None:
            return None
        return "\n".join(
            line[8:] for line in match.group("script").splitlines()
        ) + "\n"

    def service_env_names(self, service):
        block = re.search(
            r"^    environment:\n(?P<body>(?:^      .*\n)+)", service, re.MULTILINE
        )
        self.assertIsNotNone(block, "service must declare an environment block")
        return set(re.findall(r"^      - ([A-Za-z_]+)=", block.group("body"), re.MULTILINE))

    def service_volumes(self, service):
        block = re.search(
            r"^    volumes:\n(?P<body>(?:^      - .+\n)+)", service, re.MULTILINE
        )
        self.assertIsNotNone(block, "service must declare volume mounts")
        return re.findall(
            r"^      - ([^:\n]+):([^:\n]+?)(?::ro)?$", block.group("body"), re.MULTILINE
        )

    def apply_service_names(self):
        names = [
            name
            for name in self.service_names()
            if "chezmoi apply" in (self.service_command_script(self.service_block(name)) or "")
        ]
        # Control: the derived loop below must actually cover the two full-run
        # services, not pass vacuously over an empty selection.
        self.assertGreaterEqual(len(names), 2, "expected at least two full-apply services")
        return names

    def test_make_test_ubuntu_routes_to_a_full_apply_service(self):
        # Derived from what the Makefile actually runs: resolve the service the
        # target names, then require that service to exist and perform the real
        # contract — apply the checkout and run the full post-apply suite
        # (the `full` argument is run-post-apply.sh's CLI contract and is what
        # includes tests/bashunit/idempotent_test.sh).
        target = re.search(r"^test-ubuntu:.*\n\t(?P<command>.+)$", self.makefile, re.MULTILINE)
        self.assertIsNotNone(target, "Makefile must define the test-ubuntu target")
        run = re.search(
            r"docker compose -f docker/docker-compose\.yml run\s+(?:-\S+\s+)*(?P<service>[a-zA-Z0-9_-]+)\s*$",
            target.group("command"),
        )
        self.assertIsNotNone(run, "make test-ubuntu must run a docker compose service")

        service_name = run.group("service")
        script = self.service_command_script(self.service_block(service_name))
        self.assertIsNotNone(script, "%s must run a scripted command, not an interactive shell" % service_name)
        self.assertIn("chezmoi apply", script)
        self.assertIn("tests/run-post-apply.sh full", script)

    def test_apply_services_run_the_canonical_gates(self):
        # Gate integrity: every service that runs a real apply must finish with
        # the canonical Smithers gate and the full post-apply suite instead of
        # a partial command list (docs/solutions/design-patterns/
        # semantic-regression-tests-over-source-shape.md).
        for name in self.apply_service_names():
            with self.subTest(service=name):
                script = self.service_command_script(self.service_block(name))
                self.assertIn("make test-smithers", script)
                self.assertIn("tests/run-post-apply.sh full", script)

    def test_apply_services_declare_disposable_home_and_frozen_brew_bundle(self):
        # Derived over all services rather than two named ones: a real apply
        # needs MMS_DISPOSABLE_HOME (idempotent_test.sh hard-fails in a
        # container without it) and HOMEBREW_BUNDLE_NO_UPGRADE (the container
        # proves dependency presence, not upstream drift; a silent revert only
        # surfaces as wall-clock/network flakiness).
        for name in self.apply_service_names():
            with self.subTest(service=name):
                env = self.service_env_names(self.service_block(name))
                self.assertIn("MMS_DISPOSABLE_HOME", env)
                self.assertIn("HOMEBREW_BUNDLE_NO_UPGRADE", env)

    def test_staging_lands_issue_cli_docs_and_makefile_in_the_worktree(self):
        # Execute the extracted staging commands under a temp root instead of
        # mirroring their text: sources are created exactly where the declared
        # volume mounts put them, so a cp that references a path no mount
        # provides — or a dropped mount — fails here, and the assertions check
        # the staged worktree, not the script's wording.
        for name in self.apply_service_names():
            with self.subTest(service=name):
                service = self.service_block(name)
                script = self.service_command_script(service)
                staging_lines = []
                for line in script.splitlines():
                    if line.strip().startswith("cd "):
                        break
                    staging_lines.append(line)
                staging = "\n".join(staging_lines)
                self.assertIn("mkdir", staging, "no staging commands found before the cd")

                with tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    for source, destination in self.service_volumes(service):
                        host = (COMPOSE.parent / source).resolve()
                        self.assertTrue(
                            host.exists(),
                            "volume mount source %s does not exist in the repository" % source,
                        )
                        target = root / destination.lstrip("/")
                        target.parent.mkdir(parents=True, exist_ok=True)
                        if host.is_dir():
                            target.mkdir()
                            (target / "mount-marker").write_text(source)
                        else:
                            target.write_text(source)

                    result = subprocess.run(
                        ["bash", "-c", staging.replace("/home/testuser", str(root / "home/testuser"))],
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)

                    worktree = root / "home/testuser/worktree"
                    self.assertTrue((worktree / "scripts/issues").is_file())
                    self.assertTrue((worktree / "docs/issues/mount-marker").is_file())
                    self.assertTrue((worktree / "Makefile").is_file())


if __name__ == "__main__":
    unittest.main()
