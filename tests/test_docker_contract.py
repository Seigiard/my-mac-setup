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


def top_level_make_environment(**overrides):
    """An environment in which a nested `make` behaves like a top-level one.

    MAKELEVEL and MAKEFLAGS are inherited when these tests themselves run
    under `make test-python`: the first renames every diagnostic to `make[1]:`
    and the second can carry `-k` or `-i` into the child, which is precisely
    the failure suppression some of these tests exist to detect.
    """
    environment = dict(os.environ)
    for variable in ("MAKELEVEL", "MAKEFLAGS", "MFLAGS"):
        environment.pop(variable, None)
    environment.update(overrides)
    return environment


class TestDockerContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.makefile = MAKEFILE.read_text(encoding="utf-8")
        cls.compose = COMPOSE.read_text(encoding="utf-8")
        cls.dockerfile = DOCKERFILE.read_text(encoding="utf-8")
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")
        if len(FIXTURE_CANARIES) != 10:
            raise AssertionError("common.bash must define the ten canonical fixture canaries")

    def service_names(self):
        names = re.findall(r"^  ([a-zA-Z0-9_-]+):\n", self.compose, re.MULTILINE)
        self.assertTrue(names, "no services parsed from docker-compose.yml")
        return names

    def run_general_python_target(self, root, body):
        """`make test-python` against a checkout holding one fixture test.

        The fixture's marker is printed from inside the test METHOD, not at
        module level: a module-level print only proves the file was imported,
        which a discovery pattern that imports but collects nothing also
        achieves.
        """
        (root / "Makefile").write_bytes(MAKEFILE.read_bytes())
        tests = root / "tests"
        tests.mkdir()
        (tests / "test_general.py").write_text(
            "import unittest\n\n"
            "class GeneralTest(unittest.TestCase):\n"
            "    def test_general_contract(self):\n"
            "        print('general-contract-ran')\n"
            "%s\n" % body,
            encoding="utf-8",
        )
        return subprocess.run(
            ["make", "test-python"],
            cwd=root,
            env=top_level_make_environment(),
            capture_output=True,
            text=True,
        )

    def test_general_python_target_executes_general_tests(self):
        # The copied Makefile is the real producer, so this proves the public
        # target still discovers and executes repository Python tests.
        with tempfile.TemporaryDirectory() as tmp:
            result = self.run_general_python_target(Path(tmp), "        self.assertTrue(True)")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("general-contract-ran", result.stdout)
        # unittest writes its own count of what it collected and ran.
        self.assertRegex(result.stderr, r"(?m)^Ran 1 test in ")

    def test_general_python_target_fails_when_a_general_test_fails(self):
        # Without this control the gate is decorative: a discovery pattern
        # that collects nothing, or a recipe that swallowed the exit code,
        # leaves the test above green on the marker alone.
        with tempfile.TemporaryDirectory() as tmp:
            result = self.run_general_python_target(
                Path(tmp), "        self.fail('general-contract-failed')"
            )

        # make reports a failed recipe as exit 2.
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("general-contract-failed", result.stderr)

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
        # Which services apply, not how many: every caller loops over this
        # list, so a service whose launcher line stops matching takes its whole
        # share of the assertions out of the run instead of failing one.
        self.assertEqual(names, ["test-full", "test-ubuntu"])
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
        # spelling here would be a source copy, and a grep of the reader's
        # source is no better -- its header comment names the variable nine
        # times, so a rename in the function body stays green. Ask the reader
        # instead. tests/helpers/disposable-home.bash is dependency-free by
        # design (its own header) so that a plain `bash -c` can source it,
        # which is exactly how idempotent_test.sh decides whether to run real
        # chezmoi commands: feed it each service's environment and require the
        # `run` verdict that unlocks that coverage.
        marker = "MMS_DISPOSABLE_HOME"
        for name in self.apply_service_names():
            with self.subTest(service=name):
                env = self.service_env(self.service_block(name))
                self.assertEqual(env.get("HOMEBREW_BUNDLE_NO_UPGRADE"), "1")
                self.assertEqual(
                    self.disposable_home_verdict({marker: env.get(marker)}),
                    "run",
                    "%s's environment must unlock the real-apply suite" % name,
                )

    def disposable_home_verdict(self, environment):
        """What tests/helpers/disposable-home.bash answers for `environment`."""
        helper = REPOSITORY / "tests" / "helpers" / "disposable-home.bash"
        clean = dict(os.environ)
        # GITHUB_ACTIONS would turn a missing marker into `misconfigured`
        # instead of `skip`, so the negative control below could not tell the
        # two apart on a CI runner.
        clean.pop("GITHUB_ACTIONS", None)
        for key, value in environment.items():
            if value is None:
                clean.pop(key, None)
            else:
                clean[key] = value
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; mms_disposable_home_verdict', "bash", str(helper)],
            env=clean,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip()

    def test_disposable_home_helper_grants_the_run_verdict_only_for_the_marker(self):
        # The control for the assertion above: without the marker the helper
        # must not answer `run`, so a helper that answered `run` for every
        # environment could not make that assertion pass by accident.
        self.assertEqual(self.disposable_home_verdict({"MMS_DISPOSABLE_HOME": None}), "skip")

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
        # Every declared service is disposable, named rather than counted: a
        # service that loses MMS_DISPOSABLE_HOME=1 would otherwise leave the
        # loop and keep this test green on the services that remain.
        self.assertEqual(disposable, ["ubuntu", "test-full", "test-ubuntu"])

    # The three launcher steps every applying CI job runs, with the exact
    # command each must carry. Literal wiring, like `make test-python`: the
    # profile name and the `--` separator are the launcher's own interface,
    # and `--verbose` on the apply is what makes a CI failure diagnosable.
    LAUNCHER_STEPS = (
        (
            "Initialize chezmoi",
            "tests/helpers/chezmoi-unattended --profile full-fixture -- init --source=./home",
        ),
        (
            "Apply dotfiles (dry-run first)",
            "tests/helpers/chezmoi-unattended --profile full-fixture -- diff --source=./home",
        ),
        (
            "Apply dotfiles",
            "tests/helpers/chezmoi-unattended --profile full-fixture -- apply "
            "--source=./home --verbose",
        ),
    )

    def named_step_block(self, job, step_name):
        pattern = r"^      - name: %s\n(?P<body>.*?)(?=^      - name: |\Z)" % re.escape(step_name)
        match = re.search(pattern, job, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, "%s step is missing" % step_name)
        return match.group("body")

    def step_run(self, step, step_name):
        run = re.search(r"^        run: (?P<command>.+)$", step, re.MULTILINE)
        self.assertIsNotNone(run, "%s step must declare a run: command" % step_name)
        return run.group("command").strip()

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
            for step_name, command in self.LAUNCHER_STEPS:
                with self.subTest(job=name, step=step_name):
                    step = self.named_step_block(body, step_name)
                    # The whole `run:` value, not a token denylist. An earlier
                    # version rejected `||` on the dry-run line and accepted
                    # every equivalent -- `; true`, `| true`, `|| :` -- and
                    # was satisfied by a comment that merely named the
                    # command, because it was not line-anchored.
                    self.assertEqual(self.step_run(step, step_name), command)
                    # `continue-on-error: true` suppresses the step's failure
                    # outside the `run:` value, where no assertion on the
                    # command itself can see it.
                    self.assertNotIn("continue-on-error", step)
        # Which jobs apply, not how many: a job whose launcher line stops
        # matching skips the three step assertions above without failing one.
        self.assertEqual(applying, ["test-ubuntu", "test-macos"])

    def run_make_test_local(self, root, managed_rc=None):
        """`make test-local` against a chezmoi that reports three managed
        targets, two of them the credential-sensitive ones the host-partial
        profile exists to omit.

        Returns (completed process, the argv of the `diff` call). The stub
        RECORDS its argv instead of discarding it: without that, a launcher
        that forwarded every managed target -- including ~/.zshenv and
        ~/.claude.json -- is indistinguishable from one that filtered them.
        """
        bin_dir = root / "bin"
        bin_dir.mkdir()
        diff_argv = root / "diff-argv"
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
            "printf '%s\\n' \"$@\" > \"$MMS_TEST_DIFF_ARGV\"\n"
        )
        fake.chmod(0o755)
        env = top_level_make_environment()
        env["HOME"] = str(root / "home")
        env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]
        env["MMS_TEST_DIFF_ARGV"] = str(diff_argv)
        if managed_rc is not None:
            env["MMS_TEST_MANAGED_RC"] = managed_rc
        completed = subprocess.run(
            ["make", "test-local"],
            cwd=REPOSITORY,
            env=env,
            capture_output=True,
            text=True,
        )
        return completed, diff_argv

    def test_make_test_local_omits_the_credential_sensitive_targets(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            home = root / "home"
            passed, diff_argv = self.run_make_test_local(root)
            self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
            forwarded = diff_argv.read_text(encoding="utf-8").splitlines()

        # Everything the launcher forwarded that names a managed destination.
        # The two omitted ones are the whole point of the host-partial
        # profile; the third proves the filter did not simply drop every
        # target, which would also satisfy an "absent" assertion.
        self.assertEqual(
            [argument for argument in forwarded if argument.startswith(str(home))],
            [str(home / ".gitconfig")],
        )

    def test_make_test_local_propagates_the_chezmoi_exit_code(self):
        # The launcher does `exit "$managed_rc"`, so the code is knowable and
        # 19 is this test's own value. `!= 0` would also pass when the stub is
        # never found and the run dies during setup -- a failure that cannot
        # be told from the one under test. make collapses any recipe failure
        # to its own exit 2 and names the recipe's real code in its report
        # line, so that line is where the forwarded value is observable.
        with tempfile.TemporaryDirectory() as tmp:
            failed, _ = self.run_make_test_local(Path(tmp), managed_rc="19")
        self.assertEqual(failed.returncode, 2, failed.stdout + failed.stderr)
        self.assertRegex(failed.stderr, r"(?m)^make: \*\*\* \[(?:Makefile:\d+: )?test-local\] Error 19$")

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

    def test_staging_lands_the_files_the_container_runs(self):
        # Sources are created where the declared volume mounts put them, so a
        # stale cp referencing a removed mount fails here before the container
        # can run any tests.
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

                    # No mount source and no staging line can produce a local
                    # issue-tracker directory, so asserting its absence here
                    # could never go red; what remains is the positive half.
                    worktree = root / "home/testuser/worktree"
                    self.assertTrue((worktree / "scripts/check_bats_assertions.py").is_file())
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
                    # The launcher's `fail` exits 2, and `set -e` carries
                    # that out of the service script unchanged. `!= 0` would
                    # also accept a script that died on its own staging.
                    self.assertEqual(
                        failed.returncode, 2, failed.stdout + failed.stderr
                    )
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
                # 7 rather than 1: forwarding the wrapper's own code and
                # "failing somehow" are different contracts, and 1 cannot
                # tell them apart.
                with tempfile.TemporaryDirectory() as tmp:
                    failing, _, _ = self.run_apply_service_script(
                        name, Path(tmp), wrapper_exit_code=7
                    )
                self.assertEqual(
                    failing.returncode,
                    7,
                    "%s's command script must exit with tests/run-post-apply.sh full's "
                    "own code:\nstdout=%s\nstderr=%s"
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

    # A test that greps docker/Dockerfile.ubuntu for the COPY/ARG/render
    # strings used to live here. It was deleted: every grep still matched
    # after moving the `ARG` lines below the `RUN` that reads them (the break
    # it existed to catch, which leaves the build with empty fixtures), and
    # any of them went red on a harmless rename of /tmp/chezmoi-helpers.
    #
    # The contract -- the image builds with the complete fixture set -- is
    # owned by `make build-docker` / `make test-ubuntu`, this repository's
    # Docker gate: the launcher inside that RUN exits 2 on any empty fixture,
    # so the build itself fails loudly. The compose side of the fixture set
    # (each build arg carries its canary) is owned by
    # test_disposable_services_supply_the_complete_fixture_set above.

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
            # 7, not 1: the wrapper's contract is `rc=$frc` then `exit "$rc"`,
            # and a wrapper that merely exited 1 on any failure would satisfy
            # an injected 1 while having lost the code.
            stub.write_text("#!/bin/sh\nexit 7\n")
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
            self.assertEqual(
                failing.returncode,
                7,
                "run-post-apply.sh must exit with the failing suite's own code:\n%s"
                % failing.stderr,
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

    def run_make_test_ubuntu(self, root, docker_exit_code):
        """`make test-ubuntu` with a fake `docker` that exits with
        `docker_exit_code`, and both of the target's own prerequisites marked
        already-made so only the container invocation runs."""
        (root / "Makefile").write_bytes(MAKEFILE.read_bytes())
        bin_dir = root / "bin"
        bin_dir.mkdir()
        (bin_dir / "docker").write_text("#!/bin/sh\nexit %d\n" % docker_exit_code)
        (bin_dir / "docker").chmod(0o755)
        env = top_level_make_environment()
        env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]
        return subprocess.run(
            ["make", "-o", "test-python", "-o", "build-docker", "test-ubuntu"],
            cwd=root,
            env=env,
            capture_output=True,
            text=True,
        )

    def test_make_test_ubuntu_fails_when_the_container_fails(self):
        # `docker compose run` returns the container's exit code, so the only
        # way `make test-ubuntu` reports success on a real failure is the
        # recipe adding something around that invocation: a leading `-`,
        # `set +e`, a second recipe line, `|| true`, `; true`, `| true`,
        # `|| :`. An earlier version of this test enumerated the spellings it
        # rejected, then froze the literal recipe text instead -- which went
        # red on `--build` or a renamed service while still missing `.IGNORE:`
        # and `MAKEFLAGS` lines elsewhere in the file. Run the recipe and
        # watch what it does with a failure instead.
        with tempfile.TemporaryDirectory() as tmp:
            failing = self.run_make_test_ubuntu(Path(tmp), docker_exit_code=7)
        self.assertEqual(failing.returncode, 2, failing.stdout + failing.stderr)
        self.assertRegex(failing.stderr, r"(?m)^make: \*\*\* \[(?:Makefile:\d+: )?test-ubuntu\] Error 7$")

    def test_make_test_ubuntu_succeeds_when_the_container_succeeds(self):
        # Control: the same recipe and the same fake docker, succeeding.
        # Proves the failure above comes from the injected exit code rather
        # than from the target never reaching its container invocation at all.
        with tempfile.TemporaryDirectory() as tmp:
            passing = self.run_make_test_ubuntu(Path(tmp), docker_exit_code=0)
        self.assertEqual(passing.returncode, 0, passing.stdout + passing.stderr)


if __name__ == "__main__":
    unittest.main()
