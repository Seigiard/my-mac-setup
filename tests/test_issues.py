import importlib.machinery
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
SCRIPT = REPOSITORY / "scripts" / "issues"


def load_issues_module():
    if "repository_issues" in sys.modules:
        return sys.modules["repository_issues"]
    loader = importlib.machinery.SourceFileLoader("repository_issues", str(SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[loader.name] = module
    loader.exec_module(module)
    return module


def issue_text(**overrides):
    fields = {"title": "A clear title", "short_description": "A compact plain-text sentence.", "type": "bug", "category": "testing-ci", "tags": "[]", "date": "2026-08-21", "status": "open", "priority": "high"}
    fields.update(overrides)
    return ("\n".join(["---"] + ["%s: %s" % (name, value) for name, value in fields.items()]) + "\n---\n\n## Why this exists\n\nReason.\n\n## Scope\n\nScope.\n\n## Open decisions\n\nNone.\n").encode("utf-8")


class IssueFixtures(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        (self.root / ".git").mkdir()
        self.issues = self.root / "docs" / "issues"
        self.issues.mkdir(parents=True)

    def tearDown(self):
        self.temporary_directory.cleanup()

    def write_issue(self, name, contents):
        path = self.issues / name
        path.write_bytes(contents)
        return path

    def module(self):
        return load_issues_module()


class ParserTests(IssueFixtures):
    def test_parses_supported_values_and_preserves_body_bytes(self):
        body = b"\xff binary-looking body\n---\n```yaml\ntitle: prose\n```\n"
        contents = b"---\n" + b'title: "Unicode \\u2603 title"\n' + b'short_description: "A \\u00fc sentence."\n' + b"type: bug\ncategory: testing-ci\ntags: [\"cross-cutting\", \"v2\"]\n" + b"date: 2026-08-21\nstatus: open\npriority: low\n---\n" + body
        document = self.module().parse_document(self.write_issue("2026-08-21-001-unicode.md", contents))
        self.assertEqual("Unicode ☃ title", document.metadata["title"])
        self.assertEqual("A ü sentence.", document.metadata["short_description"])
        self.assertEqual(["cross-cutting", "v2"], document.metadata["tags"])
        self.assertEqual(body, document.body)

    def test_rejects_frontmatter_boundary_and_grammar_errors(self):
        cases = {"missing-leading": b"title: no boundary\n---\n", "duplicate": issue_text().replace(b"title: A clear title\n", b"title: A clear title\ntitle: duplicate\n"), "unknown": issue_text(extra="value"), "block": issue_text(title="|"), "comment": issue_text(title="title # comment"), "bad-tags": issue_text(tags="[one]"), "unsafe-tag": issue_text(tags='["not_safe"]'), "invalid-utf8": b"---\ntitle: \xff\n---\n"}
        for case, contents in cases.items():
            with self.subTest(case=case):
                with self.assertRaises(self.module().IssueError):
                    self.module().parse_document(self.write_issue("2026-08-21-001-%s.md" % case, contents))

    def test_ignores_yaml_looking_body_content_after_frontmatter(self):
        document = self.module().parse_document(self.write_issue("2026-08-21-001-body-prose.md", issue_text() + b"> ---\n```yaml\nstatus: done\n---\n```\n---\n"))
        self.assertEqual("open", document.metadata["status"])
        self.assertTrue(document.body.endswith(b"---\n"))

    def test_rejects_filename_date_disagreement_and_invalid_schema(self):
        path = self.write_issue("2026-08-20-001-wrong-date.md", issue_text())
        self.assertIn("FILENAME_DATE_MISMATCH", [item.code for item in self.module().validate_document(self.module().parse_document(path), compatibility=False)])
        invalid = self.write_issue("2026-08-21-002-invalid.md", issue_text(category="other", priority="urgent", status="paused"))
        self.assertEqual(["INVALID_CATEGORY", "INVALID_PRIORITY", "INVALID_STATUS"], [item.code for item in self.module().validate_document(self.module().parse_document(invalid), compatibility=False)])


class CorpusTests(IssueFixtures):
    def test_real_legacy_corpus_has_99_records_and_only_expected_gaps(self):
        module = self.module()
        self.assertEqual(99, len(module.discover_issue_paths(REPOSITORY)))
        output = module.validate(REPOSITORY, compatibility=True)
        self.assertEqual(99 * 4, len(output))
        self.assertTrue(all(line.startswith("MISSING_LEGACY_FIELD ") for line in output))

    def test_selects_canonical_files_and_resolves_canonical_and_compact_ids(self):
        self.write_issue("2026-08-21-001-one.md", issue_text())
        self.write_issue("2026-08-21-001-two.md", issue_text())
        self.write_issue("2026-08-21-002-only.md", issue_text())
        self.write_issue("_open-issues.md", issue_text())
        module = self.module()
        records = module.discover_issue_paths(self.root)
        self.assertEqual(["2026-08-21-001-one", "2026-08-21-001-two", "2026-08-21-002-only"], [path.stem for path in records])
        self.assertEqual("2026-08-21-002-only", module.resolve_issue_id(records, "2026-08-21-002").stem)
        with self.assertRaises(module.IssueError) as context:
            module.resolve_issue_id(records, "2026-08-21-001")
        self.assertEqual("AMBIGUOUS_ID: 2026-08-21-001 -> 2026-08-21-001-one, 2026-08-21-001-two", str(context.exception))

    def test_enforces_active_and_terminal_heading_contracts(self):
        module = self.module()
        active = self.write_issue("2026-08-21-001-active.md", issue_text())
        self.assertEqual([], module.validate_document(module.parse_document(active), compatibility=False))
        terminal = self.write_issue("2026-08-21-002-done.md", issue_text(status="done", closed="2026-08-22") + b"\n## Why this exists\n\nReason.\n\n## Resolution - 2026-08-22\n\nFixed.\n")
        self.assertEqual([], module.validate_document(module.parse_document(terminal), compatibility=False))
        missing_scope = self.write_issue("2026-08-21-003-missing-scope.md", issue_text().replace(b"\n## Scope\n\nScope.", b""))
        self.assertIn("MISSING_ACTIVE_HEADING", [item.code for item in module.validate_document(module.parse_document(missing_scope), compatibility=False)])

    def test_compatibility_reports_only_the_four_legacy_gaps_without_rewriting(self):
        legacy = b"---\ntitle: Legacy\ntype: chore\ndate: 2026-08-21\nstatus: open\n---\n\n## Why this exists\n\nReason.\n\n## Scope\n\nScope.\n\n## Open decisions\n\nNone.\n"
        path = self.write_issue("2026-08-21-001-legacy.md", legacy)
        process = subprocess.run(["python3", str(SCRIPT), "validate", "--compatibility"], cwd=self.root, capture_output=True, text=True, check=False)
        self.assertEqual(0, process.returncode, process.stderr)
        self.assertEqual(["MISSING_LEGACY_FIELD category", "MISSING_LEGACY_FIELD priority", "MISSING_LEGACY_FIELD short_description", "MISSING_LEGACY_FIELD tags"], process.stdout.splitlines())
        self.assertEqual(legacy, path.read_bytes())


class ReadTests(IssueFixtures):
    def test_version_and_show_unique_compact_id(self):
        self.write_issue("2026-08-21-001-one.md", issue_text())
        version = subprocess.run(["python3", str(SCRIPT), "--version"], cwd=self.root, capture_output=True, text=True)
        self.assertEqual((0, "repository-issues-contract 1\n"), (version.returncode, version.stdout))
        result = subprocess.run(["python3", str(SCRIPT), "show", "2026-08-21-001", "--json"], cwd=self.root, capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("2026-08-21-001-one", result.stdout)


if __name__ == "__main__":
    unittest.main()
