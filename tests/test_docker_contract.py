from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
MAKEFILE = REPOSITORY / "Makefile"
COMPOSE = REPOSITORY / "docker" / "docker-compose.yml"
DOCKERFILE = REPOSITORY / "docker" / "Dockerfile.ubuntu"
WORKFLOW = REPOSITORY / ".github" / "workflows" / "test-dotfiles.yml"
RUNNER = REPOSITORY / "tests" / "run-post-apply.sh"
LAUNCHER = REPOSITORY / "tests" / "helpers" / "chezmoi-unattended"
INVENTORY = REPOSITORY / "tests" / "helpers" / "chezmoi-unattended-targets.tsv"
COMMON_HELPERS = REPOSITORY / "tests" / "helpers" / "common.bash"
FIXTURE_CANARIES = dict(
    re.findall(
        r"^\s*(MMS_CHEZMOI_FIXTURE_[A-Z0-9_]+)=([^\s\\]+)\s*\\$",
        COMMON_HELPERS.read_text(encoding="utf-8"),
        re.MULTILINE,
    )
)


class TestDockerContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.makefile = MAKEFILE.read_text(encoding="utf-8")
        cls.compose = COMPOSE.read_text(encoding="utf-8")
        cls.dockerfile = DOCKERFILE.read_text(encoding="utf-8")
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")
        if len(FIXTURE_CANARIES) != 5:
            raise AssertionError("common.bash must define the five canonical fixture canaries")

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
            re.findall(r"^      - ([A-Za-z0-9_]+)=(.*)$", block.group("body"), re.MULTILINE)
        )

    def service_build_args(self, service):
        block = re.search(
            r"^    build:\n(?P<body>.*?)(?=^    [a-zA-Z0-9_-]+:)",
            service,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(block, "service must declare a build block")
        args = re.search(
            r"^      args:\n(?P<body>(?:^        .*\n)+)",
            block.group("body"),
            re.MULTILINE,
        )
        self.assertIsNotNone(args, "service build must declare args")
        return dict(
            re.findall(
                r"^        ([A-Za-z0-9_]+):\s*(.*)$", args.group("body"), re.MULTILINE
            )
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
            if re.search(
                r"(?m)^\s*tests/helpers/chezmoi-unattended\b.*\s--\s+apply\b",
                self.service_command_script(self.service_block(name)) or "",
            )
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
        self.assertRegex(
            script,
            r"(?m)^\s*tests/helpers/chezmoi-unattended\b.*\s--\s+apply\b",
        )
        self.assertRegex(script, r"(?m)^\s*tests/run-post-apply\.sh full\b")

    def test_apply_services_declare_disposable_home_and_frozen_brew_bundle(self):
        # HOMEBREW_BUNDLE_NO_UPGRADE is parsed verbatim by Homebrew, a tool
        # this repo does not own and cannot cheaply invoke in CI, and without
        # it a revert to drift-chasing surfaces only as wall-clock/network
        # flakiness. That is the externally-consumed-literal shape, kept.
        #
        # MMS_DISPOSABLE_HOME is consumed inside this repo, so trusting the
        # spelling here would be a source copy. Cross-check it against its
        # reader instead: tests/helpers/disposable-home.bash is what lets
        # idempotent_test.sh run its real chezmoi commands, and a rename there
        # that missed compose would drop that coverage silently.
        marker = "MMS_DISPOSABLE_HOME"
        self.assertIn(
            marker,
            (REPOSITORY / "tests" / "helpers" / "disposable-home.bash").read_text(encoding="utf-8"),
            "%s must be the marker tests/helpers/disposable-home.bash reads" % marker,
        )
        for name in self.apply_service_names():
            with self.subTest(service=name):
                env = self.service_env(self.service_block(name))
                self.assertEqual(env.get(marker), "1")
                self.assertEqual(env.get("HOMEBREW_BUNDLE_NO_UPGRADE"), "1")

    def test_disposable_services_supply_the_complete_fixture_set(self):
        disposable = []
        for name in self.service_names():
            env = self.service_env(self.service_block(name))
            if env.get("MMS_DISPOSABLE_HOME") != "1":
                continue
            disposable.append(name)
            with self.subTest(service=name):
                self.assertEqual(env.get("MMS_CHEZMOI_UNATTENDED"), "1")
                build_args = self.service_build_args(self.service_block(name))
                for fixture, canary in FIXTURE_CANARIES.items():
                    self.assertEqual(env.get(fixture), canary)
                    self.assertEqual(build_args.get(fixture), canary)
        self.assertTrue(disposable, "expected at least one disposable Docker service")

    def test_ci_apply_jobs_inherit_complete_fixtures_and_use_unsuppressed_launcher(self):
        top_env = re.search(
            r"^env:\n(?P<body>.*?)(?=^jobs:)", self.workflow, re.MULTILINE | re.DOTALL
        )
        self.assertIsNotNone(top_env, "workflow must declare top-level env")
        workflow_env = dict(
            (key, value.strip('"'))
            for key, value in re.findall(
                r"^  ([A-Za-z0-9_]+):\s*(.+)$", top_env.group("body"), re.MULTILINE
            )
        )
        self.assertEqual(workflow_env.get("MMS_CHEZMOI_UNATTENDED"), "1")
        for fixture, canary in FIXTURE_CANARIES.items():
            self.assertEqual(workflow_env.get(fixture), canary)

        jobs = re.findall(
            r"^  ([a-zA-Z0-9_-]+):\n(?P<body>.*?)(?=^  [a-zA-Z0-9_-]+:\n|\Z)",
            self.workflow,
            re.MULTILINE | re.DOTALL,
        )
        applying = []
        for name, body in jobs:
            if not re.search(r"chezmoi-unattended\b[^\n]*\s--\s+apply\b", body):
                continue
            applying.append(name)
            self.assertRegex(body, r"chezmoi-unattended\b[^\n]*\s--\s+init\b")
            diff = re.search(
                r"^\s*run:\s*(?P<command>.*chezmoi-unattended\b.*\s--\s+diff\b.*)$",
                body,
                re.MULTILINE,
            )
            self.assertIsNotNone(diff, "%s must run a launcher-based dry-run" % name)
            self.assertNotIn("||", diff.group("command"))
        self.assertGreaterEqual(len(applying), 2)

    def test_make_test_local_executes_host_partial_and_propagates_failures(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            fake = bin_dir / "chezmoi"
            fake.write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = --version ]; then echo 'chezmoi version 2.72.1'; exit 0; fi\n"
                "for arg in \"$@\"; do\n"
                "  if [ \"$arg\" = managed ]; then\n"
                "    [ \"${MMS_TEST_MANAGED_RC:-0}\" -eq 0 ] || exit \"$MMS_TEST_MANAGED_RC\"\n"
                "    printf '%s\\0' \"$HOME/.zshenv\" \"$HOME/.claude.json\" \"$HOME/.gitconfig\"\n"
                "    exit 0\n"
                "  fi\n"
                "done\n"
                "echo checked-non-sensitive-state\n"
            )
            fake.chmod(0o755)
            env = os.environ.copy()
            env["HOME"] = str(root / "home")
            env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]

            passed = subprocess.run(
                ["make", "test-local"],
                cwd=REPOSITORY,
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(passed.returncode, 0, passed.stderr)
            self.assertIn("checked-non-sensitive-state", passed.stdout)
            self.assertIn("home/dot_zshenv.tmpl", passed.stderr)
            self.assertIn("~/.zshenv", passed.stderr)
            self.assertIn("home/modify_dot_claude.json", passed.stderr)
            self.assertIn("~/.claude.json", passed.stderr)

            env["MMS_TEST_MANAGED_RC"] = "19"
            failed = subprocess.run(
                ["make", "test-local"],
                cwd=REPOSITORY,
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(failed.returncode, 0)

    def run_template_override(self, root, env_overrides=None):
        target = re.search(
            r"^test-templates:.*?(?=^\S|\Z)",
            self.makefile,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(target, "Makefile must define test-templates")
        quoted = re.search(r"'(?P<script>set -e.*?)'", target.group(0), re.DOTALL)
        self.assertIsNotNone(quoted, "test-templates must pass a command override")

        home = root / "home/testuser"
        (home / "dotfiles").mkdir(parents=True)
        (home / "dotfiles/source-marker").write_text("source")
        (home / ".local/share/chezmoi").mkdir(parents=True)
        self.populate_launcher_files(home / "tests")
        (home / "tests/lib").mkdir()
        template_marker = root / "template-tests-ran"
        (home / "tests/lib/bashunit").write_text(
            "#!/bin/sh\ntouch \"$MMS_TEST_TEMPLATE_MARKER\"\n"
        )
        (home / "tests/lib/bashunit").chmod(0o755)

        bin_dir = root / "bin"
        bin_dir.mkdir()
        calls = root / "chezmoi-calls"
        (bin_dir / "chezmoi").write_text(
            "#!/bin/sh\n"
            "if [ \"$1\" = --version ]; then echo 'chezmoi version 2.72.1'; exit 0; fi\n"
            "printf '%s\\n' \"$*\" >> \"$MMS_TEST_CHEZMOI_CALLS\"\n"
        )
        (bin_dir / "chezmoi").chmod(0o755)

        env = os.environ.copy()
        env.update(self.service_env(self.service_block("test-ubuntu")))
        env["HOME"] = str(home)
        env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]
        env["MMS_TEST_CHEZMOI_CALLS"] = str(calls)
        env["MMS_TEST_TEMPLATE_MARKER"] = str(template_marker)
        for key, value in (env_overrides or {}).items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = value

        completed = subprocess.run(
            [
                "bash",
                "-c",
                quoted.group("script").replace("/home/testuser", str(home)),
            ],
            cwd=home,
            env=env,
            capture_output=True,
            text=True,
        )
        return completed, calls, template_marker

    def test_template_override_preflights_fixtures_before_init(self):
        missing_fixture = next(iter(FIXTURE_CANARIES))
        with tempfile.TemporaryDirectory() as tmp:
            failed, calls, template_marker = self.run_template_override(
                Path(tmp), {missing_fixture: None}
            )
            self.assertNotEqual(failed.returncode, 0)
            self.assertFalse(calls.exists(), failed.stdout + failed.stderr)
            self.assertFalse(template_marker.exists(), failed.stdout + failed.stderr)

        with tempfile.TemporaryDirectory() as tmp:
            passed, calls, template_marker = self.run_template_override(Path(tmp))
            self.assertEqual(passed.returncode, 0, passed.stderr)
            self.assertIn(" init ", " " + calls.read_text() + " ")
            self.assertTrue(template_marker.exists(), passed.stdout + passed.stderr)

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

    def populate_launcher_files(self, target):
        target.mkdir(parents=True)
        (target / "helpers").mkdir()
        (target / "helpers" / "chezmoi-unattended").write_bytes(
            LAUNCHER.read_bytes()
        )
        (target / "helpers" / "chezmoi-unattended").chmod(0o755)
        (target / "helpers" / "chezmoi-unattended-targets.tsv").write_bytes(
            INVENTORY.read_bytes()
        )

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
                    self.stage_service_volumes(
                        service,
                        root,
                        overrides={"/home/testuser/tests": self.populate_launcher_files},
                    )

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
                    self.assertTrue((worktree / "tests/helpers/chezmoi-unattended").is_file())
                    self.assertTrue(
                        (worktree / "tests/helpers/chezmoi-unattended-targets.tsv").is_file()
                    )

    def run_apply_service_script(
        self, service, root, wrapper_exit_code, env_overrides=None
    ):
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
        bin_dir.mkdir(parents=True)
        calls = root / "chezmoi-calls"
        post_apply_marker = root / "post-apply-ran"
        (bin_dir / "chezmoi").write_text(
            "#!/bin/sh\n"
            "if [ \"$1\" = --version ]; then\n"
            "  echo 'chezmoi version 2.72.1'\n"
            "  exit 0\n"
            "fi\n"
            "printf '%s\\n' \"$*\" >> \"$MMS_TEST_CHEZMOI_CALLS\"\n"
            "exit 0\n"
        )
        (bin_dir / "chezmoi").chmod(0o755)
        # docker/Dockerfile.ubuntu pre-creates this at image build time
        # (`RUN mkdir -p .../.local/share/chezmoi`); the script's own first
        # real step copies into it before ever calling chezmoi, so a stub
        # rebuild of the image's filesystem baseline needs the same mkdir.
        (root / "home/testuser/.local/share/chezmoi").mkdir(parents=True)

        def populate_tests_mount(target):
            self.populate_launcher_files(target)
            (target / "lib").mkdir()
            (target / "lib" / "bashunit").write_text("#!/bin/sh\nexit 0\n")
            (target / "lib" / "bashunit").chmod(0o755)
            (target / "run-post-apply.sh").write_text(
                "#!/bin/sh\n"
                "touch \"$MMS_TEST_POST_APPLY_MARKER\"\n"
                "exit %d\n" % wrapper_exit_code
            )
            (target / "run-post-apply.sh").chmod(0o755)

        service_block = self.service_block(service)
        self.stage_service_volumes(
            service_block, root, overrides={"/home/testuser/tests": populate_tests_mount}
        )

        script = self.service_command_script(service_block)
        env = os.environ.copy()
        env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]
        env.update(self.service_env(service_block))
        env["MMS_TEST_CHEZMOI_CALLS"] = str(calls)
        env["MMS_TEST_POST_APPLY_MARKER"] = str(post_apply_marker)
        for key, value in (env_overrides or {}).items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = value
        completed = subprocess.run(
            ["bash", "-c", script.replace("/home/testuser", str(root / "home/testuser"))],
            capture_output=True,
            text=True,
            env=env,
        )
        return completed, calls, post_apply_marker

    def test_apply_services_fail_before_chezmoi_when_a_fixture_is_missing(self):
        missing_fixture = next(iter(FIXTURE_CANARIES))
        for name in self.apply_service_names():
            with self.subTest(service=name):
                with tempfile.TemporaryDirectory() as tmp:
                    failed, calls, post_apply = self.run_apply_service_script(
                        name,
                        Path(tmp),
                        wrapper_exit_code=0,
                        env_overrides={missing_fixture: None},
                    )
                    self.assertNotEqual(failed.returncode, 0)
                    self.assertFalse(calls.exists(), failed.stdout + failed.stderr)
                    self.assertFalse(post_apply.exists(), failed.stdout + failed.stderr)

                    passed, calls, post_apply = self.run_apply_service_script(
                        name, Path(tmp) / "control", wrapper_exit_code=0
                    )
                    self.assertEqual(passed.returncode, 0, passed.stderr)
                    self.assertTrue(calls.exists(), passed.stdout + passed.stderr)
                    self.assertTrue(post_apply.exists(), passed.stdout + passed.stderr)

    def test_apply_service_scripts_propagate_a_failing_post_apply_suite(self):
        # Catches a `|| true`, `set +e`, or trailing `; true` added after the
        # `tests/run-post-apply.sh full` line: the command-text assertions
        # above accept such a line unchanged because they only check that the
        # right command name is present, not that its exit code survives.
        for name in self.apply_service_names():
            with self.subTest(service=name):
                with tempfile.TemporaryDirectory() as tmp:
                    failing, _, _ = self.run_apply_service_script(
                        name, Path(tmp), wrapper_exit_code=1
                    )
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
                    passing, _, _ = self.run_apply_service_script(
                        name, Path(tmp), wrapper_exit_code=0
                    )
                self.assertEqual(
                    passing.returncode,
                    0,
                    "%s's command script must succeed when tests/run-post-apply.sh full "
                    "succeeds:\nstdout=%s\nstderr=%s" % (name, passing.stdout, passing.stderr),
                )

    def test_docker_build_uses_the_launcher_with_the_compose_canaries(self):
        copy_launcher = self.dockerfile.index(
            "COPY --chown=testuser tests/helpers/chezmoi-unattended "
        )
        copy_inventory = self.dockerfile.index(
            "COPY --chown=testuser tests/helpers/chezmoi-unattended-targets.tsv "
        )
        render = self.dockerfile.index(
            "/tmp/chezmoi-helpers/chezmoi-unattended",
            self.dockerfile.index("RUN MMS_DISPOSABLE_HOME=1"),
        )
        self.assertLess(copy_launcher, render)
        self.assertLess(copy_inventory, render)

        for fixture, canary in FIXTURE_CANARIES.items():
            with self.subTest(fixture=fixture):
                self.assertIn("ARG %s" % fixture, self.dockerfile)
                self.assertRegex(
                    self.compose,
                    r"(?m)^\s{%d}%s:\s*%s\s*$"
                    % (8, re.escape(fixture), re.escape(canary)),
                )
                self.assertIn('%s="$%s"' % (fixture, fixture), self.dockerfile)

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
            suite_dir = Path(tmp) / "suite"
            suite_dir.mkdir()
            (suite_dir / "control_test.sh").write_text(
                "#!/usr/bin/env bash\n# post-apply: 10 host-safe\n"
            )
            env["MMS_BASHUNIT_SUITE_DIR"] = str(suite_dir)
            # The wrapper's own suite-end orphan-watcher guard
            # (docs/solutions/design-patterns/outliving-processes-hang-the-suite.md)
            # scans the live `ps` table and can independently
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
