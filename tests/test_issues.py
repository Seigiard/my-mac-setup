import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from unittest import mock


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

    def run_issues(self, *arguments, **kwargs):
        options = {"cwd": self.root, "capture_output": True, "text": True, "check": False}
        options.update(kwargs)
        return subprocess.run(["python3", str(SCRIPT)] + list(arguments), **options)


class ParserTests(IssueFixtures):
    def test_parses_supported_values_and_preserves_body_bytes(self):
        body = b"\xff binary-looking body\n---\n```yaml\ntitle: prose\n```\n"
        contents = b"---\n" + b'title: "Unicode \\u2603 title"\n' + b'short_description: "A \\u00fc sentence."\n' + b"type: bug\ncategory: testing-ci\ntags: [\"cross-cutting\", \"v2\"]\n" + b"date: 2026-08-21\nstatus: open\npriority: low\n---\n" + body
        document = self.module().parse_document(self.write_issue("2026-08-21-001-unicode.md", contents))
        self.assertEqual("Unicode ☃ title", document.metadata["title"])
        self.assertEqual("A ü sentence.", document.metadata["short_description"])
        self.assertEqual(["cross-cutting", "v2"], document.metadata["tags"])
        self.assertEqual(body, document.body)

    def test_parses_a_quoted_scalar_containing_the_key_separator(self):
        path = self.write_issue("2026-08-21-001-colon.md", issue_text(short_description='"Pipeline failure: reviewer timed out"'))
        self.assertEqual("Pipeline failure: reviewer timed out", self.module().parse_document(path).metadata["short_description"])

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
        self.assertIn("FILENAME_DATE_MISMATCH", [item.code for item in self.module().validate_document(self.module().parse_document(path))])
        invalid = self.write_issue("2026-08-21-002-invalid.md", issue_text(category="other", priority="urgent", status="paused"))
        self.assertEqual(["INVALID_CATEGORY", "INVALID_PRIORITY", "INVALID_STATUS"], [item.code for item in self.module().validate_document(self.module().parse_document(invalid))])


class CorpusTests(IssueFixtures):
    def test_real_corpus_is_strictly_valid(self):
        module = self.module()
        self.assertGreater(len(module.discover_issue_paths(REPOSITORY)), 0)
        self.assertEqual([], module.validate(REPOSITORY))

    def test_strict_validate_command_accepts_the_current_corpus(self):
        process = subprocess.run(["python3", str(SCRIPT), "validate"], cwd=REPOSITORY, capture_output=True, text=True, check=False)
        self.assertEqual(0, process.returncode, process.stderr)
        self.assertEqual("", process.stdout)

    def test_discovery_inventory_includes_every_non_underscore_issue_document(self):
        expected = sorted(path.name for path in (REPOSITORY / "docs" / "issues").glob("*.md") if not path.name.startswith("_"))
        actual = [path.name for path in self.module().discover_issue_paths(REPOSITORY)]
        self.assertEqual(expected, actual)

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
        self.assertEqual([], module.validate_document(module.parse_document(active)))
        terminal = self.write_issue("2026-08-21-002-done.md", issue_text(status="done", closed="2026-08-22") + b"\n## Why this exists\n\nReason.\n\n## Resolution - 2026-08-22\n\nFixed.\n")
        self.assertEqual([], module.validate_document(module.parse_document(terminal)))
        missing_scope = self.write_issue("2026-08-21-003-missing-scope.md", issue_text().replace(b"\n## Scope\n\nScope.", b""))
        self.assertIn("MISSING_ACTIVE_HEADING", [item.code for item in module.validate_document(module.parse_document(missing_scope))])


class ReadTests(IssueFixtures):
    def test_version_and_show_unique_compact_id(self):
        self.write_issue("2026-08-21-001-one.md", issue_text())
        version = subprocess.run(["python3", str(SCRIPT), "--version"], cwd=self.root, capture_output=True, text=True)
        self.assertEqual((0, "repository-issues-contract 2\n"), (version.returncode, version.stdout))
        result = subprocess.run(["python3", str(SCRIPT), "show", "2026-08-21-001", "--json"], cwd=self.root, capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("2026-08-21-001-one", result.stdout)

    def test_list_defaults_filters_ordering_text_json_and_empty(self):
        self.write_issue("2026-08-21-003-low.md", issue_text(title="Low", short_description="Low desc", category="herdr", priority="low"))
        self.write_issue("2026-08-21-002-high.md", issue_text(title="High", short_description="High desc", category="herdr", priority="high", tags='["focus"]'))
        self.write_issue("2026-08-21-005-high.md", issue_text(title="Later high", short_description="Later high desc", category="herdr", priority="high"))
        self.write_issue("2026-08-21-004-critical.md", issue_text(title="Critical", short_description="Critical desc", category="testing-ci", priority="critical"))
        self.write_issue("2026-08-21-006-medium.md", issue_text(title="Medium", short_description="Medium desc", category="testing-ci", priority="medium"))
        self.write_issue("2026-08-21-001-done.md", issue_text(title="Done", status="done", closed="2026-08-21") + b"\n## Resolution\n\nDone.\n")
        result = self.run_issues("list")
        self.assertEqual(0, result.returncode, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual([
            "[herdr]",
            "[high] 2026-08-21-002 - High",
            "High desc",
            "",
            "[high] 2026-08-21-005 - Later high",
            "Later high desc",
            "",
            "[low] 2026-08-21-003 - Low",
            "Low desc",
            "",
            "[testing-ci]",
            "[crit] 2026-08-21-004 - Critical",
            "Critical desc",
            "",
            "[med] 2026-08-21-006 - Medium",
            "Medium desc",
            "",
        ], lines)
        self.assertNotIn("\x1b[", result.stdout)
        self.assertEqual(1, lines.count("[herdr]"))
        self.assertEqual(1, lines.count("[testing-ci]"))
        self.assertNotIn("2026-08-21-001-done", result.stdout)
        result = self.run_issues("list", "--status", "done", "--json")
        payload = json.loads(result.stdout)
        self.assertEqual(["2026-08-21-001-done"], [item["id"] for item in payload["issues"]])
        result = self.run_issues("list", "--tag", "missing", "--json")
        self.assertEqual({"issues": []}, json.loads(result.stdout))
        result = self.run_issues("list", "--category", "herdr", "--priority", "high", "--type", "bug", "--tag", "focus")
        self.assertIn("[high] 2026-08-21-002 - High", result.stdout)

    def test_formats_terminal_priority_id_title_and_description_styles(self):
        value = {"id": "2026-08-21-002-high", "priority": "high", "short_description": "High desc", "title": "High"}
        self.assertEqual("\x1b[31m[high]\x1b[0m \x1b[36m2026-08-21-002\x1b[0m - \x1b[1mHigh\x1b[0m\n\x1b[2mHigh desc\x1b[0m", self.module().format_issue_summary(value, color=True))
        value["short_description"] = "High"
        self.assertEqual("\x1b[31m[high]\x1b[0m \x1b[36m2026-08-21-002\x1b[0m - \x1b[1mHigh\x1b[0m\n\x1b[2mHigh\x1b[0m", self.module().format_issue_summary(value, color=True))

    def test_searches_title_description_and_arbitrary_body_in_stable_order(self):
        self.write_issue("2026-08-21-002-body.md", issue_text(title="Other", short_description="Nothing") + b"\xffNeedle in body.\xfe\n")
        self.write_issue("2026-08-21-001-title.md", issue_text(title="Needle title", short_description="Nothing"))
        self.write_issue("2026-08-21-003-description.md", issue_text(title="Other", short_description="Needle summary"))
        text = self.run_issues("search", "needle")
        self.assertEqual(0, text.returncode, text.stderr)
        lines = text.stdout.splitlines()
        self.assertEqual("[testing-ci]", lines[0])
        self.assertEqual(["2026-08-21-001", "2026-08-21-002", "2026-08-21-003"], [line.split()[1] for line in lines if line.startswith(("[low] ", "[med] ", "[high] ", "[crit] "))])
        payload = json.loads(self.run_issues("search", "NEEDLE", "--json").stdout)
        self.assertEqual(["2026-08-21-001-title", "2026-08-21-002-body", "2026-08-21-003-description"], [item["id"] for item in payload["issues"]])

    def test_repeated_filter_matrix_for_list_and_search(self):
        self.write_issue("2026-08-21-001-first.md", issue_text(title="Needle first", category="herdr", priority="high", type="bug", tags='["alpha","beta"]'))
        self.write_issue("2026-08-21-002-second.md", issue_text(title="Needle second", status="in-progress", category="testing-ci", priority="low", type="chore", tags='["alpha","beta","gamma"]'))
        cases = (
            (("--status", "open", "--status", "in-progress"), ["2026-08-21-001-first", "2026-08-21-002-second"]),
            (("--category", "herdr", "--category", "testing-ci"), ["2026-08-21-001-first", "2026-08-21-002-second"]),
            (("--priority", "high", "--priority", "low"), ["2026-08-21-001-first", "2026-08-21-002-second"]),
            (("--type", "bug", "--type", "chore"), ["2026-08-21-001-first", "2026-08-21-002-second"]),
            (("--category", "herdr", "--priority", "low"), []),
            (("--tag", "alpha", "--tag", "beta"), ["2026-08-21-001-first", "2026-08-21-002-second"]),
            (("--tag", "alpha", "--tag", "missing"), []),
        )
        for command in ("list", "search"):
            for filters, expected in cases:
                with self.subTest(command=command, filters=filters):
                    arguments = (command,) + (("needle",) if command == "search" else ()) + filters + ("--json",)
                    result = self.run_issues(*arguments)
                    self.assertEqual(0, result.returncode, result.stderr)
                    self.assertEqual(expected, [item["id"] for item in json.loads(result.stdout)["issues"]])

    def test_plain_show_preserves_arbitrary_body_bytes(self):
        body = b"\n## Why this exists\n\n\xffReason.\x00\n\n## Scope\n\nScope.\n\n## Open decisions\n\n\xfeNone.\n"
        frontmatter = issue_text().split(b"\n---\n", 1)[0] + b"\n---\n"
        self.write_issue("2026-08-21-001-bytes.md", frontmatter + body)
        result = self.run_issues("show", "2026-08-21-001", text=False)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(b"2026-08-21-001-bytes\nA clear title\n" + body, result.stdout)

    def test_show_json_is_deterministic_for_non_utf8_body(self):
        self.write_issue("2026-08-21-001-bytes.md", issue_text() + b"\xff\xfe\x80\n")
        first = self.run_issues("show", "2026-08-21-001", "--json")
        second = self.run_issues("show", "2026-08-21-001", "--json")
        self.assertEqual((0, first.stdout), (second.returncode, second.stdout), first.stderr)
        self.assertIn("\\xff\\xfe\\x80", json.loads(first.stdout)["body"])

    def test_reads_share_the_lock_and_do_not_create_missing_issue_storage(self):
        module = self.module()
        self.write_issue("2026-08-21-001-one.md", issue_text())
        with module.issue_lock(self.root, shared=True):
            concurrent_reader = subprocess.run(["python3", str(SCRIPT), "list"], cwd=self.root, capture_output=True, text=True, timeout=2)
        self.assertEqual(0, concurrent_reader.returncode, concurrent_reader.stderr)
        processes = []
        with module.issue_lock(self.root):
            for arguments in (("list",), ("search", "title"), ("show", "2026-08-21-001"), ("validate",)):
                processes.append(subprocess.Popen(["python3", str(SCRIPT)] + list(arguments), cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
            time.sleep(0.15)
            self.assertTrue(all(process.poll() is None for process in processes))
        for process in processes:
            process.communicate(timeout=3)
            self.assertEqual(0, process.returncode)

        empty_root = self.root / "empty"
        empty_root.mkdir()
        (empty_root / ".git").mkdir()
        result = subprocess.run(["python3", str(SCRIPT), "list"], cwd=empty_root, capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse((empty_root / "docs" / "issues" / ".issues.lock").exists())


class WriteTests(IssueFixtures):
    def test_create_assigns_the_next_utc_date_sequence_and_active_body(self):
        today = datetime.now(timezone.utc).date().isoformat()
        self.write_issue("%s-001-existing.md" % today, issue_text(date=today))
        result = self.run_issues("create", "--title", "New issue title", "--short-description", "A useful description.", "--type", "chore", "--category", "testing-ci", "--tag", "new-work", "--priority", "medium")
        self.assertEqual(0, result.returncode, result.stderr)
        path = self.issues / ("%s-002-new-issue-title.md" % today)
        document = self.module().parse_document(path)
        self.assertEqual("open", document.metadata["status"])
        self.assertEqual(["new-work"], document.metadata["tags"])
        self.assertEqual([], self.module().validate_document(document))
        self.assertEqual("docs/issues/%s-002-new-issue-title.md\n" % today, result.stdout)

    def test_create_external_id_retry_returns_original_path(self):
        arguments = ("create", "--title", "Original title", "--short-description", "Idempotent create.", "--type", "chore", "--category", "repository-maintenance", "--priority", "low", "--external-id", "smithers-run-42")
        first = self.run_issues(*arguments)
        second = self.run_issues(*(arguments[:2] + ("Changed retry title",) + arguments[3:]))
        self.assertEqual(0, first.returncode, first.stderr)
        self.assertEqual((0, first.stdout), (second.returncode, second.stdout), second.stderr)
        paths = self.module().discover_issue_paths(self.root)
        self.assertEqual(1, len(paths))
        self.assertEqual("smithers-run-42", self.module().parse_document(paths[0]).metadata["external-id"])

    def test_start_close_and_wontfix_enforce_lifecycle_rules(self):
        open_path = self.write_issue("2026-08-21-001-open.md", issue_text())
        start = self.run_issues("start", "2026-08-21-001")
        self.assertEqual(0, start.returncode, start.stderr)
        self.assertEqual("id=2026-08-21-001-open path=docs/issues/2026-08-21-001-open.md status=in-progress\n", start.stdout)
        self.assertEqual("in-progress", self.module().parse_document(open_path).metadata["status"])
        before = open_path.read_bytes()
        self.assertEqual(2, self.run_issues("start", "2026-08-21-001").returncode)
        self.assertEqual(before, open_path.read_bytes())
        close = self.run_issues("close", "2026-08-21-001", "--resolution", "Implemented and verified.")
        self.assertEqual(0, close.returncode, close.stderr)
        self.assertEqual("id=2026-08-21-001-open path=docs/issues/2026-08-21-001-open.md status=done\n", close.stdout)
        closed = self.module().parse_document(open_path)
        self.assertEqual("done", closed.metadata["status"])
        self.assertRegex(closed.metadata["closed"], r"^\d{4}-\d{2}-\d{2}$")
        self.assertEqual(1, closed.body.count(b"## Resolution"))

        before = open_path.read_bytes()
        self.assertEqual(2, self.run_issues("start", "2026-08-21-001").returncode)
        self.assertEqual(before, open_path.read_bytes())

        wontfix_path = self.write_issue("2026-08-21-002-wontfix.md", issue_text())
        wontfix = self.run_issues("wontfix", "2026-08-21-002", "--rationale", "The cost exceeds the benefit.")
        self.assertEqual(0, wontfix.returncode, wontfix.stderr)
        self.assertEqual("id=2026-08-21-002-wontfix path=docs/issues/2026-08-21-002-wontfix.md status=wontfix\n", wontfix.stdout)
        wontfix_document = self.module().parse_document(wontfix_path)
        self.assertEqual("wontfix", wontfix_document.metadata["status"])
        self.assertIn(b"The cost exceeds the benefit.", wontfix_document.body)

        in_progress_path = self.write_issue("2026-08-21-003-in-progress.md", issue_text(status="in-progress"))
        self.assertEqual(0, self.run_issues("wontfix", "2026-08-21-003", "--rationale", "Superseded.").returncode)
        self.assertEqual("wontfix", self.module().parse_document(in_progress_path).metadata["status"])

        original = wontfix_path.read_bytes()
        repeated = self.run_issues("wontfix", "2026-08-21-002", "--rationale", "No second resolution.")
        self.assertEqual(2, repeated.returncode)
        self.assertEqual(original, wontfix_path.read_bytes())

        done_path = self.write_issue("2026-08-21-004-done.md", issue_text(status="done", closed="2026-08-21") + b"\n## Why this exists\n\nReason.\n\n## Resolution\n\nDone.\n")
        before = done_path.read_bytes()
        self.assertEqual(2, self.run_issues("close", "2026-08-21-004", "--resolution", "Again.").returncode)
        self.assertEqual(before, done_path.read_bytes())

    def test_lifecycle_mutation_waits_for_the_exclusive_issue_lock(self):
        path = self.write_issue("2026-08-21-001-contended.md", issue_text())
        with self.module().issue_lock(self.root):
            process = subprocess.Popen(
                ["python3", str(SCRIPT), "start", "2026-08-21-001"],
                cwd=self.root,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            time.sleep(0.15)
            blocked = process.poll() is None

        stdout, stderr = process.communicate(timeout=3)
        self.assertTrue(blocked, stderr)
        self.assertEqual(0, process.returncode, stderr)
        self.assertEqual("id=2026-08-21-001-contended path=docs/issues/2026-08-21-001-contended.md status=in-progress\n", stdout)
        document = self.module().parse_document(path)
        self.assertEqual("in-progress", document.metadata["status"])
        self.assertEqual([], self.module().validate_document(document))

    def test_invalid_transitions_and_protected_edits_preserve_bytes(self):
        path = self.write_issue("2026-08-21-001-open.md", issue_text())
        cases = [
            ("close", "2026-08-21-001", "--resolution", "Not started."),
            ("wontfix", "2026-08-21-001", "--rationale", ""),
            ("edit", "2026-08-21-001", "--status", "done"),
            ("edit", "2026-08-21-001", "--date", "2026-08-22"),
            ("edit", "2026-08-21-001", "--closed", "2026-08-22"),
            ("start", "../2026-08-21-001"),
        ]
        for arguments in cases:
            with self.subTest(arguments=arguments):
                before = path.read_bytes()
                result = self.run_issues(*arguments)
                self.assertEqual(2, result.returncode)
                self.assertEqual(before, path.read_bytes())

    def test_atomic_replacement_rejects_a_changed_preimage(self):
        path = self.write_issue("2026-08-21-001-preimage.md", issue_text())
        before = path.read_bytes()
        path.write_bytes(before + b"Changed outside the lock.\n")
        with self.assertRaises(self.module().IssueError) as context:
            self.module().atomic_replace(path, b"replacement", before)
        self.assertEqual("PREIMAGE_CHANGED", context.exception.code)
        self.assertEqual(before + b"Changed outside the lock.\n", path.read_bytes())

    def test_atomic_replacement_preserves_existing_mode_and_creates_readable_files(self):
        module = self.module()
        path = self.write_issue("2026-08-21-001-mode.md", issue_text())
        path.chmod(0o751)
        before = path.read_bytes()
        module.atomic_replace(path, before + b"new\n", before)
        self.assertEqual(0o751, stat.S_IMODE(path.stat().st_mode))
        created = self.issues / "2026-08-21-002-created.md"
        module.atomic_replace(created, issue_text(), None)
        self.assertEqual(0o644, stat.S_IMODE(created.stat().st_mode))

    def test_atomic_create_does_not_overwrite_a_late_destination(self):
        module = self.module()
        path = self.issues / "2026-08-21-001-race.md"
        competitor = b"competitor bytes\n"
        original_link = os.link

        def create_competitor_then_link(source, destination):
            Path(destination).write_bytes(competitor)
            return original_link(source, destination)

        with mock.patch.object(module.os, "link", side_effect=create_competitor_then_link):
            with self.assertRaises(module.IssueError) as context:
                module.atomic_replace(path, b"our bytes\n", None)
        self.assertEqual("ISSUE_ALREADY_EXISTS", context.exception.code)
        self.assertEqual(competitor, path.read_bytes())
        self.assertEqual([], list(self.issues.glob(".issues-*")))

    def test_create_retries_after_link_collision_with_the_next_sequence(self):
        module = self.module()
        today = datetime.now(timezone.utc).date().isoformat()
        competitor = issue_text(date=today)
        original_link = os.link
        collided = []

        def collide_once(source, destination):
            if not collided:
                Path(destination).write_bytes(competitor)
                collided.append(Path(destination))
            return original_link(source, destination)

        arguments = SimpleNamespace(title="Retried create", short_description="Retries a collision.", type="chore", category="repository-maintenance", tag=None, priority="low", parent_plan=None, external_id=None, why="Reason.", scope="Scope.", open_decisions="None.")
        with mock.patch.object(module.os, "link", side_effect=collide_once):
            created = module.create_issue(self.root, arguments)
        self.assertEqual("%s-002-retried-create.md" % today, created.name)
        self.assertEqual(competitor, collided[0].read_bytes())
        self.assertEqual(["%s-001-retried-create.md" % today, "%s-002-retried-create.md" % today], [path.name for path in module.discover_issue_paths(self.root)])

    def test_edit_changes_only_allowed_metadata_and_rejects_terminal_issues(self):
        path = self.write_issue("2026-08-21-001-edit.md", issue_text())
        result = self.run_issues("edit", "2026-08-21-001", "--title", "Edited title", "--tag", "one", "--tag", "two", "--parent-plan", "docs/plans/example.md")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("id=2026-08-21-001-edit path=docs/issues/2026-08-21-001-edit.md status=open\n", result.stdout)
        document = self.module().parse_document(path)
        self.assertEqual("Edited title", document.metadata["title"])
        self.assertEqual(["one", "two"], document.metadata["tags"])
        self.assertEqual("docs/plans/example.md", document.metadata["parent-plan"])

        terminal = self.write_issue("2026-08-21-002-done.md", issue_text(status="done", closed="2026-08-21") + b"\n## Why this exists\n\nReason.\n\n## Resolution\n\nDone.\n")
        before = terminal.read_bytes()
        rejected = self.run_issues("edit", "2026-08-21-002", "--title", "No change")
        self.assertEqual(2, rejected.returncode)
        self.assertEqual(before, terminal.read_bytes())

    def test_canonical_stems_mutate_collided_compact_ids(self):
        first = self.write_issue("2026-08-21-001-first.md", issue_text())
        second = self.write_issue("2026-08-21-001-second.md", issue_text())
        ambiguous = self.run_issues("start", "2026-08-21-001")
        self.assertEqual(2, ambiguous.returncode)
        result = self.run_issues("start", first.stem)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("in-progress", self.module().parse_document(first).metadata["status"])
        self.assertEqual("open", self.module().parse_document(second).metadata["status"])
        edited = self.run_issues("edit", second.stem, "--priority", "medium")
        self.assertEqual(0, edited.returncode, edited.stderr)
        self.assertEqual("medium", self.module().parse_document(second).metadata["priority"])
        closed = self.run_issues("close", first.stem, "--resolution", "Closed by canonical stem.")
        self.assertEqual(0, closed.returncode, closed.stderr)
        wontfix = self.run_issues("wontfix", second.stem, "--rationale", "Rejected by canonical stem.")
        self.assertEqual(0, wontfix.returncode, wontfix.stderr)

    def test_concurrent_creates_allocate_unique_sequences(self):
        arguments = ("create", "--title", "Concurrent", "--short-description", "Concurrent create.", "--type", "chore", "--category", "repository-maintenance", "--priority", "low")
        with ThreadPoolExecutor(max_workers=8) as executor:
            results = list(executor.map(lambda _: self.run_issues(*arguments), range(12)))
        self.assertTrue(all(result.returncode == 0 for result in results), [result.stderr for result in results])
        paths = [result.stdout.strip() for result in results]
        self.assertEqual(12, len(set(paths)))

    def test_two_concurrent_starts_have_one_valid_winner(self):
        path = self.write_issue("2026-08-21-001-concurrent-start.md", issue_text())
        with self.module().issue_lock(self.root):
            processes = [subprocess.Popen(["python3", str(SCRIPT), "start", "2026-08-21-001"], cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(2)]
            time.sleep(0.15)
            self.assertTrue(all(process.poll() is None for process in processes))
        results = [(process.communicate(timeout=3), process.returncode) for process in processes]
        self.assertEqual([0, 2], sorted(returncode for _, returncode in results))
        errors = [stderr for ((_, stderr), returncode) in results if returncode == 2]
        self.assertEqual(1, len(errors))
        self.assertIn("INVALID_TRANSITION", errors[0])
        document = self.module().parse_document(path)
        self.assertEqual("in-progress", document.metadata["status"])
        self.assertEqual([], self.module().validate_document(document))

    def test_lock_guards_and_sequence_exhaustion(self):
        lock = self.issues / ".issues.lock"
        lock.symlink_to(self.issues / "target")
        result = self.run_issues("create", "--title", "Blocked", "--short-description", "Blocked.", "--type", "chore", "--category", "repository-maintenance", "--priority", "low")
        self.assertEqual(2, result.returncode)
        lock.unlink()
        lock.mkdir()
        self.assertEqual(2, self.run_issues("list").returncode)
        lock.rmdir()
        today = datetime.now(timezone.utc).date().isoformat()
        self.write_issue("%s-999-last.md" % today, issue_text(date=today))
        exhausted = self.run_issues("create", "--title", "No slot", "--short-description", "No slot.", "--type", "chore", "--category", "repository-maintenance", "--priority", "low")
        self.assertEqual(2, exhausted.returncode)
        self.assertIn("SEQUENCE_EXHAUSTED", exhausted.stderr)


class ClientDiscoveryTests(unittest.TestCase):
    def test_clients_share_the_canonical_repository_issues_skill(self):
        skill = REPOSITORY / ".claude" / "skills" / "repository-issues" / "SKILL.md"
        self.assertTrue(skill.is_file())
        contents = skill.read_text()
        self.assertIn("name: repository-issues", contents)
        self.assertIn("short_description", contents)
        self.assertIn("testing-ci", contents)
        self.assertIn("repository-maintenance", contents)
        self.assertIn("critical", contents)
        self.assertIn("low", contents)
        for command in ("list", "show", "search", "create", "start", "edit", "close", "wontfix", "validate"):
            self.assertIn(command, contents)
        self.assertIn("unresolved", contents.lower())

        opencode_skill = REPOSITORY / ".opencode" / "skills" / "repository-issues"
        self.assertTrue(opencode_skill.is_symlink())
        self.assertFalse(Path(opencode_skill.readlink()).is_absolute())
        self.assertEqual(skill, opencode_skill.resolve() / "SKILL.md")

        pi_settings = REPOSITORY / ".pi" / "settings.json"
        self.assertEqual({"skills": ["../.claude/skills"]}, json.loads(pi_settings.read_text()))

        agents = REPOSITORY / "AGENTS.md"
        self.assertTrue(agents.is_symlink())
        self.assertEqual(Path("CLAUDE.md"), agents.readlink())
        self.assertEqual((REPOSITORY / "CLAUDE.md").resolve(), agents.resolve())

        policy = (REPOSITORY / "CLAUDE.md").read_text()
        self.assertIn("repository-issues", policy)
        self.assertIn("scripts/issues", policy)
        self.assertIn("docs/issues", policy)

        ignored = (REPOSITORY / ".gitignore").read_text().splitlines()
        self.assertIn("docs/issues/.issues.lock", ignored)
        self.assertNotIn(".claude", ignored)
        self.assertNotIn(".opencode", ignored)
        self.assertNotIn(".pi", ignored)


if __name__ == "__main__":
    unittest.main()
