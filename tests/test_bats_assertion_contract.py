from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
CHECKER = REPOSITORY / "scripts" / "check_bats_assertions.py"


class TestBatsAssertionContract(unittest.TestCase):
    def run_checker(self, files):
        with tempfile.TemporaryDirectory() as temp_dir:
            tests_dir = Path(temp_dir) / "tests"
            tests_dir.mkdir()
            for relative_path, content in files.items():
                path = tests_dir / relative_path
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(CHECKER), str(tests_dir)],
                text=True,
                capture_output=True,
                check=False,
            )

    def test_rejects_bare_conditional_commands(self):
        result = self.run_checker(
            {
                "unsafe.bats": """@test "conditional" {
  local attempt=2
  local delay=$(( 1 << attempt ))
  printf '%s\n' 'quoted example: <<FAKE'
  # Commented example: <<COMMENT
  run cat <<<'a here-string is not a heredoc'
  [[ 1 == 2 ]]
  :
}
""",
                "nested/unsafe.bats": """@test "arithmetic" {
  (( 0 ))
}
""",
                "nested/semicolon.bats": """@test "semicolon" {
  run true; [[ 1 == 2 ]]
  :
}
""",
                "nested/second-conditional.bats": """@test "second conditional" {
  [[ 1 == 1 ]] || fail "first"; [[ 1 == 2 ]]
  :
}
""",
                "nested/second-arithmetic.bats": """@test "second arithmetic" {
  (( 1 )) || fail "first"; (( 0 ))
  :
}
""",
                "nested/second-and.bats": """@test "second after and" {
  [[ 1 == 1 ]] || fail "first" && [[ 1 == 2 ]]; :
}
""",
                "nested/second-or.bats": """@test "second after or" {
  (( 0 )) && fail "first" || (( 0 )); :
}
"""
            }
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("unsafe.bats:8: bare [[...]]", result.stdout)
        self.assertIn("nested/unsafe.bats:2: bare ((...))", result.stdout)
        self.assertIn("nested/semicolon.bats:2: bare [[...]]", result.stdout)
        self.assertIn("nested/second-conditional.bats:2: bare [[...]]", result.stdout)
        self.assertIn("nested/second-arithmetic.bats:2: bare ((...))", result.stdout)
        self.assertIn("nested/second-and.bats:2: bare [[...]]", result.stdout)
        self.assertIn("nested/second-or.bats:2: bare ((...))", result.stdout)

    def test_accepts_explicit_handlers_control_flow_and_heredocs(self):
        result = self.run_checker(
            {
                "safe.bats": """@test "safe forms" {
  [[ 1 == 1 ]] || fail "expected equality"
  [[ 1 == 1 ]] || fail "literal ]] remains safe"
  [[ 1 == 1 ]] \\
    || fail "expected multiline equality"
  [[ -e /tmp/ready ]] && break
  (( count > 0 )) || fail "expected a positive count"
  [[ 1 == 1 ]] || fail "first"; [[ 2 == 2 ]] || fail "second"
  [[ 1 == 1 ]] || fail "first" && [[ 2 == 2 ]] || fail "second"
  (( 0 )) && fail "first" || (( 1 )) || fail "second"
  if [[ -e /tmp/optional ]]; then
    :
  fi
  if true && [[ -e /tmp/optional ]]; then
    :
  fi
  while (( count > 0 )); do
    break
  done
  while true && (( count > 0 )); do
    break
  done
  cat <<'SCRIPT'
  [[ generated == shell ]]
  (( generated_arithmetic ))
SCRIPT
  cat <<PLAIN
	PLAIN
  [[ still_generated == shell ]]
PLAIN
  run jq -e '
    ((.items | length) == 1)
  ' <<< "$output"
}
""",
                "helpers/bats-libs/vendor.bats": """@test "vendored" {
  [[ 1 == 2 ]]
  :
}
""",
            }
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_repository_has_no_implicit_conditional_assertions(self):
        result = subprocess.run(
            [sys.executable, str(CHECKER), str(REPOSITORY / "tests")],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
