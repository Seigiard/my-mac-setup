"""The real bridge, CLI and native leaf preserve the caller's execution contract."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parent / "helpers"))
from intercom_recovery_adapters import FakeHerdr, recovery

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "home/dot_local"


class CallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="intercom callers ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.lib = self.root / "lib"
        self.lib.mkdir()
        for name in ("intercom-claim-recovery.py", "herdr-agent-intercom-native-claude"):
            source = SOURCE / "lib" / (name if name.endswith(".py") else "executable_" + name)
            (self.lib / name).write_bytes(source.read_bytes())
            (self.lib / name).chmod(0o700)
        self.native = self.root / "native"
        self.native.write_text(
            f"#!{sys.executable}\nimport json,os,sys\n"
            "print(json.dumps({'pid':os.getpid(),'argv':sys.argv[1:],"
            "'enrolled':os.environ.get('HERDR_AGENT_INTERCOM_ACTIVE'),"
            "'intent':os.environ.get('HERDR_AGENT_INTERCOM_RECOVERY_INTENT')}))\n")
        self.native.chmod(0o700)
        self.state = self.root / "recovery"
        self.host = recovery.Host()
        self.host.parent_pid = os.getpid
        self.host.ensure_owner = lambda root: True
        self.host.alias_candidates = lambda seed: ["silver-ibis"]
        self.server = FakeHerdr()
        self.engine = recovery.RecoveryEngine(self.state, host=self.host, sessions=self.server)

    def admit(self):
        result = self.engine.admit(socket_path="fake.sock", pane_id="w1:p1", agent="claude", launcher_pid=os.getpid())
        self.assertEqual(result.launch.route, "claimed")
        return result.intent_id

    def run_bridge(self, handle, original, generated, status=0, enrolled="1"):
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("HERDR_AGENT_INTERCOM_", "AGENT_INTERCOM_", "CLAUDE_INTERCOM_"))}
        env.update(HERDR_AGENT_INTERCOM_LIB_DIR=str(self.lib), HERDR_AGENT_INTERCOM_PYTHON=sys.executable,
                   HERDR_AGENT_INTERCOM_RECOVERY_ROOT=str(self.state),
                   HERDR_AGENT_INTERCOM_RECOVERY_INTENT=handle,
                   HERDR_AGENT_INTERCOM_ACTIVE="1", AGENT_INTERCOM_CLAUDE_COMMAND=str(self.native),
                   AGENT_INTERCOM_CLAUDE_ARGC=str(len(original)))
        env.update({f"AGENT_INTERCOM_CLAUDE_ARG_{index}": value for index, value in enumerate(original)})
        with subprocess.Popen(["bash", str(SOURCE / "bin/executable_herdr-agent-intercom-claude"), *generated],
                              env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, status, stderr)
            result = json.loads(stdout)
            self.assertEqual(result["pid"], process.pid)
            self.assertEqual(result["enrolled"], enrolled)
            return result

    def test_bound_execution_preserves_permissions_empty_values_and_terminator(self):
        # #given an admitted launch with native options cci cannot reconstruct
        handle = self.admit()
        original = ["--permission-mode", "plan", "--model", "", "--", "--version", "two words"]
        # #when cci supplies its generated controls
        result = self.run_bridge(handle, original, ["--permission-mode", "manual", "--plugin-dir", "plugin path"])
        # #then only generated permission defaults are discarded, before the terminator
        self.assertEqual(result["argv"], ["--permission-mode", "plan", "--model", "", "--plugin-dir", "plugin path",
                                         "--", "--version", "two words"])
        self.assertEqual(result["intent"], handle)

    def test_unavailable_and_path_handles_start_original_native_argv_only(self):
        # #given handles that cannot authorize enrollment
        for handle in ("pruned-handle", "../foreign.json", str(self.root / "foreign.json")):
            with self.subTest(handle=handle):
                original = ["--dangerously-skip-permissions", "--", "message"]
                # #when the actual bind-exec path rejects them
                result = self.run_bridge(handle, original, ["--plugin-dir", "generated", "identity prompt"], enrolled=None)
                # #then fallback keeps the native argv and drops enrollment
                self.assertEqual(result["argv"], original)
                self.assertIsNone(result["intent"])

    def test_version_probe_does_not_restore_interactive_argv_or_consume_binding(self):
        # #given a live obligation
        handle = self.admit()
        # #when cci probes its bridge
        probe = self.run_bridge(handle, ["--model", "sonnet", "message"], ["--version"])
        # #then only the utility runs, and the next invocation can still bind
        self.assertEqual(probe["argv"], ["--version"])
        native = self.run_bridge(handle, ["--no-chrome"], ["--permission-mode", "manual", "--plugin-dir", "plugin"])
        self.assertEqual(native["argv"], ["--no-chrome", "--plugin-dir", "plugin"])

    def test_repeated_binding_cannot_authorize_generated_arguments(self):
        # #given an obligation whose native binding was already consumed
        handle = self.admit()
        self.run_bridge(handle, [], ["--plugin-dir", "plugin"])
        # #when a second bridge arrives
        result = self.run_bridge(handle, ["original"], ["generated"], enrolled=None)
        # #then it preserves native startup without re-enrollment
        self.assertEqual(result["argv"], ["original"])


if __name__ == "__main__":
    unittest.main()
