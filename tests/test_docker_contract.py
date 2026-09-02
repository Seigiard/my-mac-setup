from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
MAKEFILE = REPOSITORY / "Makefile"
COMPOSE = REPOSITORY / "docker" / "docker-compose.yml"
RUNNER = REPOSITORY / "tests" / "run-post-apply.sh"


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

    def service_env(self, service):
        block = re.search(
            r"^    environment:\n(?P<body>(?:^      .*\n)+)", service, re.MULTILINE
        )
        self.assertIsNotNone(block, "service must declare an environment block")
        return dict(
            re.findall(r"^      - ([A-Za-z_]+)=(.*)$", block.group("body"), re.MULTILINE)
        )

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
        # An empty selection would let every caller pass vacuously.
        self.assertGreaterEqual(len(names), 2, "expected at least two full-apply services")
        return names

    def test_make_test_ubuntu_routes_to_a_full_apply_service(self):
        # No compose-text check for idempotent_test.sh: its only matches in
        # docker-compose.yml are comments. Reachability is owned by
        # tests/test_post_apply_suite_contract.py.
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
        # Line-anchored so a comment or an echo that merely mentions the
        # command cannot satisfy the assertion.
        self.assertRegex(script, r"(?m)^\s*chezmoi apply\b")
        self.assertRegex(script, r"(?m)^\s*tests/run-post-apply\.sh full\b")

    def test_apply_services_run_the_full_post_apply_suite(self):
        for name in self.apply_service_names():
            with self.subTest(service=name):
                script = self.service_command_script(self.service_block(name))
                self.assertRegex(script, r"(?m)^\s*tests/run-post-apply\.sh full\b")

    def test_apply_services_declare_disposable_home_and_frozen_brew_bundle(self):
        # idempotent_test.sh hard-fails in a container without
        # MMS_DISPOSABLE_HOME; without HOMEBREW_BUNDLE_NO_UPGRADE a revert to
        # drift-chasing surfaces only as wall-clock/network flakiness.
        for name in self.apply_service_names():
            with self.subTest(service=name):
                env = self.service_env(self.service_block(name))
                self.assertEqual(env.get("MMS_DISPOSABLE_HOME"), "1")
                self.assertEqual(env.get("HOMEBREW_BUNDLE_NO_UPGRADE"), "1")

    def stage_service_volumes(self, service, root, overrides=None):
        """Populate fake mount sources for `service`'s volumes at `root`, so
        the staging `cp` lines in its command script have something real to
        copy. `overrides` maps a destination mount path (e.g.
        "/home/testuser/tests") to a callable(Path) that writes real content
        into the staged target instead of the generic empty-dir marker used
        by every other mount, whose content the scripts under test never
        inspect."""
        overrides = overrides or {}
        for source, destination in self.service_volumes(service):
            host = (COMPOSE.parent / source).resolve()
            self.assertTrue(
                host.exists(),
                "volume mount source %s does not exist in the repository" % source,
            )
            target = root / destination.lstrip("/")
            target.parent.mkdir(parents=True, exist_ok=True)
            if destination in overrides:
                overrides[destination](target)
            elif host.is_dir():
                target.mkdir()
                (target / "mount-marker").write_text(source)
            else:
                target.write_text(source)

    def test_staging_lands_issue_cli_docs_and_makefile_in_the_worktree(self):
        # Sources are created where the declared volume mounts put them, so a
        # cp referencing a path no mount provides — or a dropped mount — fails
        # here.
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
                self.assertTrue(staging.strip(), "no staging commands found before the cd")

                with tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    self.stage_service_volumes(service, root)

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

    def run_apply_service_script(self, service, root, wrapper_exit_code):
        """Run `service`'s complete command script (staging, chezmoi, both
        test gates) against a fake worktree at `root`, under a stubbed PATH.

        chezmoi and the pre-apply bashunit gate are stubbed to always
        succeed: this proves the script's OWN control flow (does `set -e`
        survive intact, is there a `|| true` or `set +e` hiding downstream
        of the post-apply suite), not chezmoi's behavior or real bashunit
        assertions -- those are covered by other suites.
        tests/run-post-apply.sh is stubbed to exit with `wrapper_exit_code`,
        so this test isolates whether the OUTER script forwards that one
        exit code; whether the wrapper itself computes the right code from
        its suite files is covered separately by
        test_run_post_apply_propagates_a_failing_suite below.
        """
        bin_dir = root / "stub-bin"
        bin_dir.mkdir()
        (bin_dir / "chezmoi").write_text("#!/bin/sh\nexit 0\n")
        (bin_dir / "chezmoi").chmod(0o755)
        # docker/Dockerfile.ubuntu pre-creates this at image build time
        # (`RUN mkdir -p .../.local/share/chezmoi`); the script's own first
        # real step copies into it before ever calling chezmoi, so a stub
        # rebuild of the image's filesystem baseline needs the same mkdir.
        (root / "home/testuser/.local/share/chezmoi").mkdir(parents=True)

        def populate_tests_mount(target):
            target.mkdir(parents=True)
            (target / "lib").mkdir()
            (target / "lib" / "bashunit").write_text("#!/bin/sh\nexit 0\n")
            (target / "lib" / "bashunit").chmod(0o755)
            (target / "run-post-apply.sh").write_text(
                "#!/bin/sh\nexit %d\n" % wrapper_exit_code
            )
            (target / "run-post-apply.sh").chmod(0o755)

        service_block = self.service_block(service)
        self.stage_service_volumes(
            service_block, root, overrides={"/home/testuser/tests": populate_tests_mount}
        )

        script = self.service_command_script(service_block)
        env = os.environ.copy()
        env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]
        return subprocess.run(
            ["bash", "-c", script.replace("/home/testuser", str(root / "home/testuser"))],
            capture_output=True,
            text=True,
            env=env,
        )

    def test_apply_service_scripts_propagate_a_failing_post_apply_suite(self):
        # Catches a `|| true`, `set +e`, or trailing `; true` added after the
        # `tests/run-post-apply.sh full` line: the command-text assertions
        # above accept such a line unchanged because they only check that the
        # right command name is present, not that its exit code survives.
        for name in self.apply_service_names():
            with self.subTest(service=name):
                with tempfile.TemporaryDirectory() as tmp:
                    failing = self.run_apply_service_script(name, Path(tmp), wrapper_exit_code=1)
                self.assertNotEqual(
                    failing.returncode,
                    0,
                    "%s's command script must fail when tests/run-post-apply.sh full "
                    "fails, but exited 0:\nstdout=%s\nstderr=%s"
                    % (name, failing.stdout, failing.stderr),
                )

                # Control: identical script and staging, wrapper succeeds
                # instead. Proves the failure above is caused by the
                # injected exit code, not by unrelated staging/setup noise
                # that would fail regardless of run-post-apply.sh's result.
                with tempfile.TemporaryDirectory() as tmp:
                    passing = self.run_apply_service_script(name, Path(tmp), wrapper_exit_code=0)
                self.assertEqual(
                    passing.returncode,
                    0,
                    "%s's command script must succeed when tests/run-post-apply.sh full "
                    "succeeds:\nstdout=%s\nstderr=%s" % (name, passing.stdout, passing.stderr),
                )

    def test_run_post_apply_propagates_a_failing_suite(self):
        # The innermost gate: tests/run-post-apply.sh tracks each suite
        # file's exit code into $rc and does `exit "$rc"` at the end. A
        # regression here (e.g. losing the `rc=$frc` assignment, or a stray
        # `|| true` on the bashunit invocation) would make every layer above
        # it -- the compose scripts, the Makefile target -- report success
        # for a real suite failure no matter how faithfully they forward
        # their own child's exit code.
        with tempfile.TemporaryDirectory() as tmp:
            stub = Path(tmp) / "bashunit"
            stub.write_text("#!/bin/sh\nexit 1\n")
            stub.chmod(0o755)
            env = os.environ.copy()
            env["MMS_BASHUNIT_BIN"] = str(stub)
            # The wrapper's own suite-end orphan-watcher guard (docs/issues/
            # 2026-08-28-001) scans the live `ps` table and can independently
            # force rc=1 when it finds an unrelated abandoned herdr-child
            # watcher rooted at this checkout -- a real condition in this
            # repo's own herdr-based dev environment, not a suite-exit-code
            # regression. Stub `ps` to report no processes so that guard is
            # inert and this test isolates only the suite rc -> wrapper exit
            # code contract, for both the failing run and its control.
            ps_stub_dir = Path(tmp) / "ps-stub-bin"
            ps_stub_dir.mkdir()
            ps_stub = ps_stub_dir / "ps"
            ps_stub.write_text("#!/bin/sh\nexit 0\n")
            ps_stub.chmod(0o755)
            env["PATH"] = str(ps_stub_dir) + os.pathsep + env["PATH"]

            failing = subprocess.run(
                [str(RUNNER), "host-safe"],
                cwd=REPOSITORY,
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(
                failing.returncode,
                0,
                "run-post-apply.sh must exit nonzero when a suite fails:\n%s" % failing.stderr,
            )

            # Control: same wrapper, env shape, and stubbed ps; stub now
            # succeeds. Isolates the failure above as caused by the injected
            # suite failure, not by host process-table state or setup noise.
            stub.write_text("#!/bin/sh\nexit 0\n")
            stub.chmod(0o755)
            passing = subprocess.run(
                [str(RUNNER), "host-safe"],
                cwd=REPOSITORY,
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                passing.returncode,
                0,
                "run-post-apply.sh must exit zero when every suite succeeds:\n%s" % passing.stderr,
            )

    def test_make_test_ubuntu_recipe_does_not_swallow_a_failing_run(self):
        # `docker compose run` already returns the container's real exit
        # code, so the only way `make test-ubuntu` could still report success
        # on a real failure is the recipe body adding anything around that
        # invocation: a leading `-`, `set +e`, a second recipe line, or a
        # trailing suppression clause. An earlier version of this check
        # enumerated specific suppression spellings (`|| true`, `; true`) and
        # missed just-as-common equivalents like `|| :`, `|| exit 0`, or
        # `| true` -- a denylist of shell idioms can never be exhaustive.
        # Assert an allowlist instead: the recipe body must be EXACTLY the
        # docker compose invocation, alone, with nothing appended. This is a
        # literal-shape check on purpose: the suppression syntax IS the
        # contract here, the same way make's own leading-`-` convention is;
        # exact-match is just a stronger literal check than a denylist scan.
        target = re.search(
            r"^test-ubuntu:.*\n(?P<body>(?:\t.*\n?)+)", self.makefile, re.MULTILINE
        )
        self.assertIsNotNone(target, "Makefile must define the test-ubuntu target")
        body = target.group("body")
        self.assertTrue(body.strip(), "test-ubuntu target has no recipe body")
        recipe_lines = [line[1:] for line in body.splitlines() if line.startswith("\t")]
        self.assertEqual(
            len(recipe_lines),
            1,
            "test-ubuntu's recipe must be a single command line -- a second "
            "line could suppress the first's exit code (e.g. 'set +e', or "
            "any command that resets $?): %r" % recipe_lines,
        )
        self.assertEqual(
            recipe_lines[0].strip(),
            "docker compose -f docker/docker-compose.yml run --rm test-ubuntu",
            "test-ubuntu's recipe must be exactly the docker compose "
            "invocation with nothing appended (no leading '-', and no "
            "trailing '||', ';', '|', or comment) that could swallow its "
            "exit code: %r" % recipe_lines[0],
        )


if __name__ == "__main__":
    unittest.main()
