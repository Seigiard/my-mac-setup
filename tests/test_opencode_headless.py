"""Public CLI checks for the approved PR #479 lifecycle contract."""

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "home/dot_local/bin/executable_opencode-headless.py"
FIXTURE = ROOT / "tests/fixtures/opencode-headless/opencode.py"


class HeadlessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="headless contract ")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.bin = self.base / "bin"
        self.bin.mkdir()
        binary = self.bin / "opencode"
        shutil.copyfile(FIXTURE, binary)
        binary.chmod(0o755)
        self.cwd = self.base / "checkout"
        self.cwd.mkdir()
        self.run = self.base / "artifacts"
        self.prompt = self.base / "prompt.md"
        self.prompt.write_text("--leading-dash 'quoted' $(touch SHOULD_NOT_EXIST)\nsecond line\n")
        self.observation = self.base / "observed.json"
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        PWD="/wrong/inherited/path", FAKE_OBSERVATION=str(self.observation),
                        XDG_DATA_HOME=str(self.base / "native-data"),
                        FAKE_READY=str(self.base / "ready"), FAKE_RELEASE=str(self.base / "release"))

    def command(self, action="launch", *extra):
        command = [sys.executable, str(CLI), action, "--run", str(self.run)]
        if action != "cleanup":
            command += ["--prompt-file", str(self.prompt)]
        if action == "launch":
            command += ["--cwd", str(self.cwd), "--model", "openai/model with 'quotes'"]
        return command + list(extra)

    def invoke(self, action="launch", *extra, status=0, mode="valid"):
        result = subprocess.run(self.command(action, *extra), cwd=self.base,
                                env=dict(self.env, FAKE_MODE=mode), input="must not reach OpenCode",
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
        return json.loads(result.stdout or result.stderr)

    def git(self, *args):
        result = subprocess.run(["git", "-C", str(self.cwd), *args], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def repository(self):
        self.git("init", "-q")
        (self.cwd / "tracked").write_text("original\n")
        self.git("add", "tracked")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
                 "commit", "-qm", "Fixture base")

    def wait_for(self, predicate, description):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.02)
        self.fail("did not observe " + description)

    def start_waiting(self, *extra):
        process = subprocess.Popen(self.command("launch", *extra), cwd=self.base,
                                   env=dict(self.env, FAKE_MODE="wait"), stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

        def finish():
            (self.base / "release").touch()
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=10)
        self.addCleanup(finish)
        self.wait_for(lambda: (self.base / "ready").exists(), "fake's post-session ready marker")
        return process

    def test_argv_cwd_stdin_and_task_verdict_are_independent(self):
        # given
        attachment = self.base / "--story 'one'.png"
        attachment.write_bytes(b"fixture attachment bytes")
        # when
        result = self.invoke("launch", "--auto", "-f", str(attachment))
        # then
        observed = json.loads(self.observation.read_text())
        self.assertEqual(observed, {"cwd": str(self.cwd), "PWD": str(self.cwd), "stdin": "",
                                   "argv": ["run", "--standalone", "--format=json", "--model=openai/model with 'quotes'",
                                            "--auto", "--file=" + str(attachment), "--", self.prompt.read_text()]})
        self.assertEqual(result["classification"], "transport-ok")
        self.assertEqual(result["exit_code"], 0)
        self.assertEqual(Path(result["answer"]).read_text(), "Task rejected: missing evidence.")
        self.assertEqual((self.run / "turn-0001/stderr.log").read_text(), "fixture diagnostic on stderr\n")
        self.assertFalse((self.cwd / "SHOULD_NOT_EXIST").exists())

    def test_separate_resume_keeps_session_model_and_prior_artifacts(self):
        # given
        self.invoke()
        first = {path.name: path.read_bytes() for path in (self.run / "turn-0001").iterdir()}
        # when
        result = self.invoke("resume")
        # then
        self.assertEqual(result["sessionID"], "ses_fixture")
        self.assertEqual(result["attempt"], str(self.run / "turn-0002"))
        self.assertEqual(json.loads(self.observation.read_text())["argv"],
                         ["run", "--standalone", "--format=json", "--model=openai/model with 'quotes'",
                          "--session=ses_fixture", "--", self.prompt.read_text()])
        self.assertEqual({path.name: path.read_bytes() for path in (self.run / "turn-0001").iterdir()}, first)
        self.invoke(status=1)
        self.assertEqual((self.run / "turn-0001/events.jsonl").read_bytes(), first["events.jsonl"])

    def test_rejects_failed_and_incomplete_transports_beside_valid_control(self):
        # given
        cases = [("valid", 0, "transport-ok", 0), ("error", 1, "failure", 0),
                 ("malformed", 1, "failure", 0), ("bad-part", 1, "failure", 0),
                 ("no-session", 1, "failure", 0), ("empty", 1, "incomplete", 0),
                 ("nonzero", 1, "failure", 7), ("signal", 1, "incomplete", -signal.SIGTERM)]
        for mode, status, classification, code in cases:
            with self.subTest(mode=mode):
                self.run = self.base / mode
                # when
                result = self.invoke(status=status, mode=mode)
                # then
                self.assertEqual((result["classification"], result["exit_code"]), (classification, code))
                self.assertEqual(json.loads((self.run / "turn-0001/status.json").read_text()), result)
                self.assertTrue((self.run / "state.json").exists())

    def test_wrong_session_resume_is_rejected_without_losing_original_session(self):
        # given
        self.invoke()
        # when
        result = self.invoke("resume", status=1, mode="wrong-session")
        # then
        self.assertEqual(result["classification"], "failure")
        self.assertEqual(json.loads((self.run / "state.json").read_text())["sessionID"], "ses_fixture")
        self.invoke("resume")

    def test_review_uses_detached_worktree_and_keeps_logs_after_cleanup(self):
        # given
        self.repository()
        (self.cwd / "existing dirty file").write_text("baseline\n")
        before = self.git("status", "--porcelain=v1", "--untracked-files=all")
        # when
        result = self.invoke("launch", "--review-ref", "HEAD")
        # then
        worktree = self.run / "worktree"
        self.assertEqual(json.loads(self.observation.read_text())["cwd"], str(worktree))
        self.assertEqual((worktree / "tracked").read_text(), "original\n")
        detached = subprocess.run(["git", "-C", str(worktree), "symbolic-ref", "-q", "HEAD"],
                                  capture_output=True)
        self.assertEqual(detached.returncode, 1)
        self.assertEqual(result["epic_unchanged"], True)
        self.assertEqual(self.git("status", "--porcelain=v1", "--untracked-files=all"), before)
        self.invoke("resume")
        self.invoke("cleanup")
        self.assertFalse(worktree.exists())
        self.assertFalse((self.run / "state.json").exists())
        self.assertEqual(self.git("worktree", "list", "--porcelain").count("worktree "), 1)
        self.assertEqual(Path(result["answer"]).read_text(), "Task rejected: missing evidence.")

    def test_epic_mutation_rejects_text_on_initial_and_resumed_turn(self):
        # given
        self.repository()
        self.env["FAKE_EPIC_FILE"] = str(self.cwd / "tracked")
        # when
        result = self.invoke("launch", "--review-ref", "HEAD", mode="mutate-epic", status=1)
        resumed = self.invoke("resume", status=1)
        # then
        self.assertEqual((result["epic_unchanged"], result["classification"]), (False, "failure"))
        self.assertEqual((resumed["epic_unchanged"], resumed["classification"]), (False, "failure"))
        self.invoke("cleanup")

    def test_cleanup_failure_retains_state_then_retry_removes_worktree(self):
        # given
        self.repository()
        self.invoke("launch", "--review-ref", "HEAD")
        self.git("worktree", "lock", str(self.run / "worktree"))
        before = (self.run / "state.json").read_bytes()
        # when
        self.invoke("cleanup", status=1)
        # then
        self.assertEqual((self.run / "state.json").read_bytes(), before)
        self.assertTrue((self.run / "worktree/tracked").exists())
        self.git("worktree", "unlock", str(self.run / "worktree"))
        self.invoke("cleanup")
        self.assertFalse((self.run / "state.json").exists())

    def test_handled_interrupt_finishes_once_then_allows_same_session_resume_and_cleanup(self):
        # given
        self.repository()
        process = self.start_waiting("--review-ref", "HEAD")
        # when
        self.invoke("cleanup", status=1)
        self.invoke("resume", status=1)
        # then
        self.assertTrue((self.run / "worktree/tracked").exists())
        self.assertTrue((self.run / "state.json").exists())
        process.send_signal(signal.SIGTERM)
        self.wait_for(lambda: (self.base / "ready.interrupt").exists(), "native interrupt handler")
        process.send_signal(signal.SIGHUP)
        self.invoke("cleanup", status=1)
        (self.base / "release").touch()
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 1, stdout + stderr)
        result = json.loads(stdout)
        self.assertEqual((result["classification"], result["exit_code"], result["quiescent"]),
                         ("incomplete", 130, True))
        self.assertTrue((self.base / "ready.settled").exists())
        resumed = self.invoke("resume")
        self.assertEqual(resumed["sessionID"], "ses_fixture")
        self.invoke("cleanup")
        self.assertFalse((self.run / "worktree").exists())

    def test_killed_wrapper_refuses_resume_even_after_cli_process_group_exits(self):
        # given
        if sys.platform == "linux":
            import ctypes
            # Container PID 1 may not reap orphans; this test owns that duty.
            libc = ctypes.CDLL(None, use_errno=True)
            self.assertEqual(libc.prctl(36, 1, 0, 0, 0), 0)
            self.addCleanup(libc.prctl, 36, 0, 0, 0, 0)
        process = self.start_waiting()
        pgid = json.loads((self.run / "turn-0001/process.json").read_text())["pgid"]

        def exited():
            if sys.platform == "linux":
                try:
                    os.waitpid(pgid, os.WNOHANG)
                except ChildProcessError:
                    pass
            try:
                os.killpg(pgid, 0)
            except ProcessLookupError:
                return True
            return False

        def release_and_reap():
            (self.base / "release").touch()
            self.wait_for(exited, "orphan transport exit")
        self.addCleanup(release_and_reap)
        # when
        process.kill()
        process.communicate(timeout=10)
        self.assertEqual(process.returncode, -signal.SIGKILL)
        self.invoke("cleanup", status=1)
        self.invoke("resume", status=1)
        # then
        self.assertIsNone(json.loads((self.run / "state.json").read_text())["sessionID"])
        (self.base / "release").touch()

        self.wait_for(exited, "orphan transport exit")
        self.invoke("resume", status=1)
        self.invoke("cleanup", status=1)
        self.assertEqual(json.loads((self.run / "turn-0001/status.json").read_text()),
                         {"classification": "incomplete", "exit_code": None, "quiescent": False})

    def test_direct_cleanup_retains_checkout_and_empty_output_cannot_resume(self):
        # given
        (self.cwd / "keep").write_text("keep\n")
        self.invoke(mode="empty", status=1)
        # when
        self.invoke("resume", status=1)
        self.invoke("cleanup")
        # then
        self.assertEqual((self.cwd / "keep").read_text(), "keep\n")
        self.assertFalse((self.run / "state.json").exists())

    def test_missing_saved_binary_records_launch_failure_and_keeps_recovery(self):
        # given
        self.invoke()
        (self.bin / "opencode").unlink()
        # when
        result = self.invoke("resume", status=1)
        # then
        self.assertEqual(result["classification"], "failure")
        self.assertEqual(json.loads((self.run / "state.json").read_text())["sessionID"], "ses_fixture")
        self.assertFalse((self.run / "turn-0002").exists())
        self.invoke("cleanup")

    def test_v2_reconciliation_joins_suffixes_but_separates_parts_and_messages(self):
        # given
        # when
        result = self.invoke(mode="suffix")
        # then
        self.assertEqual(Path(result["answer"]).read_text(), "Read /tmp/report.md\nToken: ABCDEF\nNext message")

    def test_v1_uses_inprocess_run_and_export_and_replaces_full_part_updates(self):
        # given
        self.env["FAKE_MAJOR"] = "1"
        # when
        first = self.invoke(mode="v1-update")
        result = self.invoke("resume")
        # then
        self.assertEqual(Path(first["answer"]).read_text(), "Read /tmp/report.md")
        self.assertEqual(json.loads(self.observation.read_text())["argv"],
                         ["run", "--format=json", "--model=openai/model with 'quotes'",
                          "--session=ses_fixture", "--", self.prompt.read_text()])
        export = json.loads((Path(result["attempt"]) / "session-check.request.json").read_text())
        self.assertEqual(export["argv"][1:], ["export", "ses_fixture"])

    def test_missing_native_session_is_rejected_before_any_resume_prompt(self):
        # given
        self.invoke()
        previous = self.observation.read_bytes()
        (self.base / "native-data/fixture-session.json").unlink()
        # when
        self.invoke("resume", status=1)
        # then
        self.assertEqual(self.observation.read_bytes(), previous)
        self.assertFalse((self.base / "native-data/fixture-session.json").exists())
        self.assertTrue((self.run / "state.json").exists())
        self.invoke("cleanup")

    def test_failed_preflight_keeps_diagnostics_and_can_retry_the_same_session(self):
        # given
        self.invoke()
        previous = self.observation.read_bytes()
        # when
        self.invoke("resume", status=1, mode="export-error")
        # then
        self.assertEqual(self.observation.read_bytes(), previous)
        failed = self.run / "turn-0002"
        evidence = {path.name: path.read_bytes() for path in failed.iterdir()}
        self.assertEqual(json.loads((failed / "session-check.status.json").read_text()), {"exit_code": 1})
        resumed = self.invoke("resume")
        self.assertEqual(resumed["sessionID"], "ses_fixture")
        self.assertEqual({path.name: path.read_bytes() for path in failed.iterdir()}, evidence)

    def test_failed_preflight_allows_review_worktree_cleanup(self):
        # given
        self.repository()
        self.invoke("launch", "--review-ref", "HEAD")
        self.invoke("resume", status=1, mode="export-error")
        # when
        self.invoke("cleanup")
        # then
        self.assertFalse((self.run / "worktree").exists())
        self.assertFalse((self.run / "state.json").exists())
        self.assertEqual((self.run / "turn-0002/session-check.stderr").read_text(), "Fixture export failed\n")

    def test_provider_failure_can_resume_and_cleanup_without_becoming_task_success(self):
        # given
        self.repository()
        first = self.invoke("launch", "--review-ref", "HEAD", mode="provider-error", status=1)
        # when
        resumed = self.invoke("resume")
        failed_again = self.invoke("resume", mode="provider-error", status=1)
        self.invoke("cleanup")
        # then
        self.assertEqual((first["classification"], first["exit_code"]), ("failure", 1))
        self.assertEqual(resumed["sessionID"], first["sessionID"])
        self.assertEqual((failed_again["classification"], failed_again["exit_code"]), ("failure", 1))
        self.assertFalse((self.run / "worktree").exists())

    def test_resume_uses_saved_storage_even_when_invoking_environment_changes(self):
        # given
        self.invoke()
        self.env["XDG_DATA_HOME"] = str(self.base / "other-native-data")
        # when
        self.invoke("resume")
        # then
        self.assertFalse((self.base / "other-native-data").exists())
        self.assertEqual(json.loads((self.run / "turn-0002/session-check.json").read_text())["info"]["id"], "ses_fixture")

    def test_wrong_session_location_is_rejected_before_resume_prompt(self):
        # given
        self.invoke()
        previous = self.observation.read_bytes()
        # when
        self.invoke("resume", status=1, mode="wrong-location")
        # then
        self.assertEqual(self.observation.read_bytes(), previous)

    def test_invalid_export_and_empty_history_cannot_authorize_resume(self):
        # given
        self.invoke()
        previous = self.observation.read_bytes()
        # when
        self.invoke("resume", status=1, mode="bad-export")
        self.invoke("resume", status=1, mode="no-history")
        # then
        self.assertEqual(self.observation.read_bytes(), previous)
        self.invoke("resume")

    def test_legacy_run_with_unknown_server_ownership_requires_operator_recovery(self):
        # given
        self.repository()
        self.invoke("launch", "--review-ref", "HEAD")
        path = self.run / "state.json"
        state = json.loads(path.read_text())
        del state["cli_version"]
        path.write_text(json.dumps(state))
        # when
        self.invoke("resume", status=1)
        self.invoke("cleanup", status=1)
        # then
        self.assertTrue((self.run / "worktree/tracked").exists())
        self.assertTrue(path.exists())

    def test_known_quiescent_turn_can_recover_missing_session_record_from_jsonl(self):
        # given
        self.invoke()
        state_path = self.run / "state.json"
        state = json.loads(state_path.read_text())
        state["sessionID"] = None
        state_path.write_text(json.dumps(state))
        # when
        result = self.invoke("resume")
        # then
        self.assertEqual(result["sessionID"], "ses_fixture")

    def test_empty_prompt_preserves_prepared_review_for_explicit_cleanup(self):
        # given
        self.repository()
        self.prompt.write_text(" \n")
        # when
        self.invoke("launch", "--review-ref", "HEAD", status=1)
        # then
        self.assertTrue((self.run / "worktree/tracked").exists())
        self.invoke("cleanup")
        self.assertFalse((self.run / "worktree").exists())

    def test_cleanup_removes_registration_when_worktree_path_is_already_absent(self):
        # given
        self.repository()
        self.invoke("launch", "--review-ref", "HEAD")
        shutil.rmtree(self.run / "worktree")
        # when
        self.invoke("cleanup")
        # then
        self.assertEqual(self.git("worktree", "list", "--porcelain").count("worktree "), 1)
        self.assertFalse((self.run / "state.json").exists())

    def test_review_artifacts_inside_epic_are_rejected(self):
        # given
        self.repository()
        self.run = self.cwd / "unsafe-artifacts"
        # when
        self.invoke("launch", "--review-ref", "HEAD", status=1)
        # then
        self.assertEqual(self.git("worktree", "list", "--porcelain").count("worktree "), 1)
        self.assertFalse(self.observation.exists())


if __name__ == "__main__":
    unittest.main()
