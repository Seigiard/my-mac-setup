import re
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[1]
HARNESS = REPOSITORY / "tests" / "style-ab"
MAKEFILE = REPOSITORY / "Makefile"
WORKFLOWS = REPOSITORY / ".github" / "workflows"

# The harness spends API credits and can bind a port. Nothing automated may
# reach it, under either spelling a Python module or a Make target could use.
FORBIDDEN = ("style-ab", "style_ab", "tests/style-ab")


class HarnessIsolationTest(unittest.TestCase):
    """T1. The oracle is the stdlib loader and the literal strings CI consumes.

    Consumer: the `make test-issues` step and the GitHub workflow that runs it.
    Observable failure: a pull-request run starts spending API credits, or starts
    a rating server, because `tests/style-ab/` became discoverable.
    """

    def discovered_ids(self):
        """Ask the real loader, in process.

        Stdlib `unittest discover` has no list or dry-run flag, so a subprocess
        would execute every test to enumerate ids.
        """
        suite = unittest.TestLoader().discover(str(REPOSITORY / "tests"), pattern="test_*.py")
        found = []
        stack = [suite]
        while stack:
            item = stack.pop()
            if isinstance(item, unittest.TestSuite):
                stack.extend(item)
            else:
                found.append(item.id())
        return found

    def test_discovery_resolves_no_test_inside_the_harness_directory(self):
        # #given the loader `make test-issues` runs
        found = self.discovered_ids()

        # #then no id comes from the harness directory, so no automated gate can
        # execute it
        offenders = [test_id for test_id in found
                     if test_id.split(".")[0].startswith(("style-ab", "style_ab"))]
        self.assertEqual(offenders, [])

        # #and the control: discovery did run and did find this repository's
        # tests, so an empty result cannot pass as isolation
        self.assertTrue([t for t in found if t.startswith("test_issues.")],
                        "discovery found no test_issues ids, so it found nothing at all")

    def test_no_package_marker_makes_the_harness_importable(self):
        # #given the mechanism the loader keys on: `_find_test_path` returns
        # early for a directory with no `__init__.py`, before the name matters
        markers = sorted(str(p.relative_to(REPOSITORY)) for p in HARNESS.rglob("__init__.py"))

        # #then none exists, so the protection is the package marker and not the
        # hyphen a maintainer might assume is doing the work
        self.assertEqual(markers, [])

    def test_no_other_target_and_no_workflow_step_reaches_the_harness(self):
        # #given every Make recipe except the one manual target, and every
        # workflow file. A recipe line is a line starting with a tab, so a
        # comment between targets belongs to no target.
        bodies = {}
        current = None
        for line in MAKEFILE.read_text().splitlines():
            if re.match(r"^[A-Za-z0-9_.-]+:", line):
                current = line.split(":")[0]
                bodies.setdefault(current, []).append(line)  # prerequisites count
            elif line.startswith("\t") and current:
                # An echo prints the name, it does not run the target, so the
                # help text is not an invocation.
                if line.lstrip("\t").lstrip("@").startswith("echo "):
                    continue
                bodies[current].append(line)

        sources = {f"Make target {name}": "\n".join(lines)
                   for name, lines in bodies.items() if name != "style-ab"}
        for workflow in sorted(WORKFLOWS.glob("*.y*ml")):
            sources[str(workflow.relative_to(REPOSITORY))] = workflow.read_text()

        # #then none of them names the harness under any spelling, so no
        # automated gate can invoke it. The literal invocation string is what
        # CI consumes, which is why a literal assertion is the right shape here.
        for name, body in sources.items():
            if name == "Make target .PHONY":
                continue  # declaring a target phony is not invoking it
            for token in FORBIDDEN:
                self.assertNotIn(token, body, f"{name} reaches the harness via {token!r}")

    def test_the_manual_target_exists_and_states_its_cost(self):
        # #given the one intended entry point
        makefile = MAKEFILE.read_text()

        # #then it exists, is phony, and its help line warns that it spends API
        # credits, so nobody runs it expecting a free check
        self.assertRegex(makefile, r"(?m)^style-ab:")
        self.assertRegex(makefile, r"(?m)^\.PHONY:.*\bstyle-ab\b")
        help_line = [line for line in makefile.splitlines() if "make style-ab" in line]
        self.assertTrue(help_line, "make style-ab is missing from the help output")
        self.assertIn("API", help_line[0])


if __name__ == "__main__":
    unittest.main()
