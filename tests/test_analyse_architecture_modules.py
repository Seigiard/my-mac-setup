"""analyse-architecture modules.py: module-level co-change and import evidence."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "home/private_dot_agents/skills/analyse-architecture/scripts/modules.py"
MODULES = ["--module", "src/a", "--module", "src/b", "--module", "src/c"]


class ModulesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)

    def run_json(self, *args):
        result = subprocess.run(["python3", str(SCRIPT), *args, "--json"],
                                capture_output=True, text=True, cwd=self.base)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def git(self, *args):
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
        subprocess.run(["git", *args], cwd=self.base, env=env, check=True,
                       capture_output=True)

    def commit(self, *paths):
        for path in paths:
            file = self.base / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(file.read_text() + "x" if file.exists() else "x")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "change")

    def history(self):
        self.git("init", "-q")
        self.commit("src/a/x.ts", "src/b/y.ts")
        self.commit("src/a/x.ts", "src/b/y.ts")
        self.commit("src/a/z.ts", "src/b/y.ts")
        self.commit("src/a/x.ts", "docs/readme.md")
        self.commit("src/c/w.ts", "src/a/x.ts")
        self.commit("src/a/x.ts", "src/b/y.ts", "src/c/w.ts", "src/c/v.ts")

    def test_cochange_counts_pairs_per_module_and_skips_bulk_commits(self):
        self.history()
        data = self.run_json("cochange", *MODULES, "--since", "", "--max-files", "3",
                             "--min-together", "1")
        self.assertEqual(data, {
            "commits_analysed": 5,
            "commits_skipped_bulk": 1,
            "modules": {"src/a": 5, "src/b": 3, "src/c": 1},
            "pairs": [
                {"a": "src/a", "b": "src/b", "together": 3, "ratio": 1.0},
                {"a": "src/a", "b": "src/c", "together": 1, "ratio": 1.0},
            ],
        })

    def test_cochange_default_threshold_drops_rare_pairs(self):
        self.history()
        data = self.run_json("cochange", *MODULES, "--since", "", "--max-files", "3")
        self.assertEqual(data["pairs"],
                         [{"a": "src/a", "b": "src/b", "together": 3, "ratio": 1.0}])

    def test_imports_reports_edges_two_way_pairs_and_separate_cycles(self):
        graph = {
            "a/x.ts": ["b/y.ts", "a/z.ts"],
            "a/z.ts": ["vendor/lib.js"],
            "b/y.ts": ["c/w.ts"],
            "c/w.ts": ["a/x.ts"],
            "d/q.ts": ["e/r.ts", "a/x.ts"],
            "e/r.ts": ["d/q.ts"],
            "f/s.ts": ["a/x.ts"],
        }
        (self.base / "graph.json").write_text(json.dumps(graph))
        data = self.run_json("imports", "graph.json", "--prefix", "src", *MODULES,
                             "--module", "src/d", "--module", "src/e",
                             "--module", "src/f")
        module = lambda fan_in, fan_out, internal, external: {
            "fan_in": fan_in, "fan_out": fan_out,
            "internal_imports": internal, "external_imports": external}
        self.assertEqual(data, {
            "modules": {
                "src/a": module(3, 1, 1, 1),
                "src/b": module(1, 1, 0, 1),
                "src/c": module(1, 1, 0, 1),
                "src/d": module(1, 2, 0, 2),
                "src/e": module(1, 1, 0, 1),
                "src/f": module(0, 1, 0, 1),
            },
            "edges": [
                {"from": "src/a", "to": "src/b", "imports": 1},
                {"from": "src/b", "to": "src/c", "imports": 1},
                {"from": "src/c", "to": "src/a", "imports": 1},
                {"from": "src/d", "to": "src/a", "imports": 1},
                {"from": "src/d", "to": "src/e", "imports": 1},
                {"from": "src/e", "to": "src/d", "imports": 1},
                {"from": "src/f", "to": "src/a", "imports": 1},
            ],
            "two_way": [{"a": "src/d", "b": "src/e", "a_to_b": 1, "b_to_a": 1}],
            "cycles": [["src/a", "src/b", "src/c"], ["src/d", "src/e"]],
        })


if __name__ == "__main__":
    unittest.main()
