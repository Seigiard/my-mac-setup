from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
CHECKER = REPOSITORY / "scripts" / "check_bats_assertions.py"


class TestBatsAssertionContract(unittest.TestCase):
    # The checker's report line, with the scan root stripped off. Reported
    # verbatim to whoever runs `make lint`, so the whole line is the contract.
    VIOLATION = "%s:%d: bare %s requires explicit status handling"

    def run_checker(self, files):
        """(exit status, every reported violation with the scan root stripped).

        The full report is returned, not searched, so a checker that starts
        flagging a negative control fails here instead of passing on the
        strength of the violations it still gets right."""
        with tempfile.TemporaryDirectory() as temp_dir:
            tests_dir = Path(temp_dir) / "tests"
            tests_dir.mkdir()
            for relative_path, content in files.items():
                path = tests_dir / relative_path
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(CHECKER), str(tests_dir)],
                text=True,
                capture_output=True,
                check=False,
            )
        prefix = str(tests_dir) + "/"
        return result, [
            line.replace(prefix, "") for line in result.stdout.splitlines()
        ]

    def test_rejects_bare_conditional_commands(self):
        # Every fixture below carries exactly one bare conditional on a known
        # line; lines 2-6 of the first one are negative controls (arithmetic
        # `<<`, a quoted heredoc marker, a commented marker, a here-string)
        # that the checker must NOT report. Asserting the complete report is
        # what makes them controls: a checker that flags line 3's `1 <<
        # attempt` as an unterminated heredoc, or line 6's here-string, can no
        # longer hide behind the seven violations it still finds.
        result, violations = self.run_checker(
            {
                "bashunit/unsafe_test.sh": """function test_conditional() {
  local attempt=2
  local delay=$(( 1 << attempt ))
  printf '%s\n' 'quoted example: <<FAKE'
  # Commented example: <<COMMENT
  run cat <<<'a here-string is not a heredoc'
  [[ 1 == 2 ]]
  :
}
""",
                "nested/bashunit/unsafe_test.sh": """function test_arithmetic() {
  (( 0 ))
}
""",
                "nested/bashunit/semicolon_test.sh": """function test_semicolon() {
  run true; [[ 1 == 2 ]]
  :
}
""",
                "nested/bashunit/second_conditional_test.sh": """function test_second_conditional() {
  [[ 1 == 1 ]] || fail "first"; [[ 1 == 2 ]]
  :
}
""",
                "nested/bashunit/second_arithmetic_test.sh": """function test_second_arithmetic() {
  (( 1 )) || fail "first"; (( 0 ))
  :
}
""",
                "nested/bashunit/second_and_test.sh": """function test_second_and() {
  [[ 1 == 1 ]] || fail "first" && [[ 1 == 2 ]]; :
}
""",
                "nested/bashunit/second_or_test.sh": """function test_second_or() {
  (( 0 )) && fail "first" || (( 0 )); :
}
"""
            }
        )

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(
            violations,
            [
                self.VIOLATION % ("bashunit/unsafe_test.sh", 8, "[[...]]"),
                self.VIOLATION % ("nested/bashunit/second_and_test.sh", 2, "[[...]]"),
                self.VIOLATION % ("nested/bashunit/second_arithmetic_test.sh", 2, "((...))"),
                self.VIOLATION % ("nested/bashunit/second_conditional_test.sh", 2, "[[...]]"),
                self.VIOLATION % ("nested/bashunit/second_or_test.sh", 2, "((...))"),
                self.VIOLATION % ("nested/bashunit/semicolon_test.sh", 2, "[[...]]"),
                self.VIOLATION % ("nested/bashunit/unsafe_test.sh", 2, "((...))"),
            ],
        )

    def test_accepts_explicit_handlers_control_flow_and_heredocs(self):
        result, _ = self.run_checker(
            {
                "bashunit/safe_test.sh": """function test_safe_forms() {
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
            }
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_scans_every_declared_shell_file_class(self):
        # One violation and one clean control per class scanned_files()
        # claims to reach. If a class silently drops out of scanned_files
        # (a broken glob, a narrowed pattern), its violation stops being
        # reported and this test fails for that class specifically. The nested
        # helper pins the recursive scope: a flat helpers glob leaves it
        # unscanned. The clean control beside each violation is what the
        # complete report below turns into a discriminator.
        result, violations = self.run_checker(
            {
                "bashunit/reachable_test.sh": """function test_reachable() {
  [[ 1 == 2 ]]
  :
}
""",
                "bashunit/reachable_clean_test.sh": """function test_reachable_control() {
  [[ 1 == 1 ]] || fail "control"
}
""",
                "helpers/reachable.bash": """reachable_helper() {
  [[ 1 == 2 ]]
  :
}
""",
                "helpers/reachable_clean.bash": """reachable_helper_control() {
  [[ 1 == 1 ]] || return 1
}
""",
                "helpers/nested/reachable.bash": """reachable_nested_helper() {
  [[ 1 == 2 ]]
  :
}
""",
                "helpers/nested/reachable_clean.bash": """reachable_nested_helper_control() {
  [[ 1 == 1 ]] || return 1
}
""",
                "bashunit/reachable.bash": """reachable_dsl_helper() {
  [[ 1 == 2 ]]
  :
}
""",
                "bashunit/reachable_clean.bash": """reachable_dsl_helper_control() {
  [[ 1 == 1 ]] || return 1
}
""",
            }
        )

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(
            violations,
            [
                self.VIOLATION % ("bashunit/reachable_test.sh", 2, "[[...]]"),
                self.VIOLATION % ("helpers/nested/reachable.bash", 2, "[[...]]"),
                self.VIOLATION % ("helpers/reachable.bash", 2, "[[...]]"),
                self.VIOLATION % ("bashunit/reachable.bash", 2, "[[...]]"),
            ],
        )

    # `make lint` runs `python3 scripts/check_bats_assertions.py tests` over
    # this repository's own tests, so a test that did the same here asserted
    # repository state a lint gate already owns, not the checker's behavior.
    # The tests above own the checker; the lint gate owns the tree.


if __name__ == "__main__":
    unittest.main()
