import hashlib
import importlib.machinery
import importlib.util
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[1]
VARIANTS = REPOSITORY / "tests" / "style-ab" / "variants.py"
MEASURED = REPOSITORY / "home" / ".chezmoitemplates" / "writing-style.md"


def load_variants_module():
    """Load the harness module by path.

    `tests/style-ab/` carries no `__init__.py` on purpose, so it is not importable
    and `unittest discover` never walks into it. Follows `load_issues_module()`.
    """
    if "style_ab_variants" in sys.modules:
        return sys.modules["style_ab_variants"]
    loader = importlib.machinery.SourceFileLoader("style_ab_variants", str(VARIANTS))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    # Register only after a successful exec. Registering first, as the issues
    # tests do for a module with circular imports, would cache a half-built
    # module and report a later AttributeError instead of the real load error.
    loader.exec_module(module)
    sys.modules[loader.name] = module
    return module


class ArmResolutionTest(unittest.TestCase):
    """T2. The oracle is the bytes of the measured file, which this change never touches.

    Consumer: an engineer measuring an edit to the shared writing style.
    Observable failure: an arm injects stale or unrendered text, so the run measures
    something no reader ever sees and the report attributes it to the edit.
    """

    def setUp(self):
        self.variants = load_variants_module()

    def test_working_tree_arm_returns_the_measured_files_exact_bytes(self):
        # #given the measured file as it stands in the working tree
        expected = MEASURED.read_bytes()

        # #when the candidate arm resolves from the working tree
        arm = self.variants.resolve("worktree", REPOSITORY)

        # #then it carries those bytes and their digest, unmodified
        self.assertEqual(arm.text.encode("utf-8"), expected)
        self.assertEqual(arm.sha256, hashlib.sha256(expected).hexdigest())

    def test_path_arm_returns_that_files_bytes_unchanged(self):
        # #given a copy of the measured file at an arbitrary path
        # This is the control for the working-tree case: a different resolution
        # route reaching the same bytes proves the route did not transform them.
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp) / "style-copy.md"
            shutil.copyfile(MEASURED, copy)

            # #when the arm resolves from that path
            arm = self.variants.resolve(str(copy), REPOSITORY)

            # #then the bytes survive the round trip
            self.assertEqual(arm.text.encode("utf-8"), MEASURED.read_bytes())

    def test_a_template_action_in_the_arm_is_refused(self):
        # #given a style file that still carries an unrendered Go template action
        with tempfile.TemporaryDirectory() as tmp:
            unrendered = Path(tmp) / "unrendered.md"
            unrendered.write_text("# Style\n\nHello {{ .name }}, read the rules.\n")

            # #when the arm resolves from it
            # #then resolution refuses rather than measuring template source
            with self.assertRaises(self.variants.UnrenderedTemplate):
                self.variants.resolve(str(unrendered), REPOSITORY)

    def test_base_arm_is_an_empty_system_prompt(self):
        # #given the control arm
        # #when it resolves
        arm = self.variants.resolve("base", REPOSITORY)

        # #then it carries no instruction text at all
        self.assertEqual(arm.text, "")
        self.assertEqual(arm.sha256, hashlib.sha256(b"").hexdigest())

    def test_ref_arm_records_the_commit_it_resolved_to(self):
        # #given a ref rather than a mutable path
        # #when the arm resolves
        arm = self.variants.resolve("HEAD", REPOSITORY)

        # #then the report can name the commit, because a ref moves and a path is mutable
        expected_commit = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=REPOSITORY, capture_output=True, text=True, check=True,
        ).stdout.strip()
        self.assertEqual(arm.commit, expected_commit)
        self.assertEqual(arm.sha256, hashlib.sha256(arm.text.encode("utf-8")).hexdigest())

    def test_every_arm_reports_a_token_count(self):
        # #given the control and a populated arm
        # #when both resolve
        base = self.variants.resolve("base", REPOSITORY)
        candidate = self.variants.resolve("worktree", REPOSITORY)

        # #then each carries a token count, so a rule set that grows without
        # changing behaviour is visible in the report header (R11)
        self.assertEqual(base.tokens, 0)
        self.assertGreater(candidate.tokens, 0)


if __name__ == "__main__":
    unittest.main()
