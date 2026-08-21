import importlib.machinery
import importlib.util
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone


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
    def test_real_migrated_corpus_has_99_strictly_valid_records(self):
        module = self.module()
        self.assertEqual(99, len(module.discover_issue_paths(REPOSITORY)))
        self.assertEqual([], module.validate(REPOSITORY, compatibility=False))

    def test_strict_validate_command_accepts_the_migrated_corpus(self):
        process = subprocess.run(["python3", str(SCRIPT), "validate"], cwd=REPOSITORY, capture_output=True, text=True, check=False)
        self.assertEqual(0, process.returncode, process.stderr)
        self.assertEqual("", process.stdout)

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


class MigrationTests(IssueFixtures):
    def test_scaffold_covers_the_sorted_real_corpus_with_preimage_hashes(self):
        module = self.module()
        manifest = module.build_migration_manifest(REPOSITORY, "17e741fcc3908ef3ca57a80f4063752f7fe6c4e6")
        paths = [entry["path"] for entry in manifest["entries"]]
        expected_paths = [str(path.relative_to(REPOSITORY)) for path in module.discover_issue_paths(REPOSITORY)]
        self.assertEqual(99, len(paths))
        self.assertEqual(expected_paths, paths)
        self.assertEqual(paths, sorted(paths))
        self.assertEqual(len(paths), len(set(paths)))
        for entry in manifest["entries"]:
            self.assertEqual(module.sha256(REPOSITORY / entry["path"]), entry["before_sha256"])
            self.assertFalse(set(entry["proposed_metadata"]["tags"]) & module.STATUSES)

    def test_check_rejects_an_issue_changed_after_scaffolding(self):
        module = self.module()
        path = self.write_issue("2026-08-21-001-stale.md", issue_text())
        (self.issues / "_open-issues.md").write_text("# Open issues\n")
        manifest = module.build_migration_manifest(self.root, "fixture-source")
        path.write_bytes(path.read_bytes() + b"Changed after scaffold.\n")
        with self.assertRaises(module.IssueError) as context:
            module.check_migration_manifest(self.root, manifest, "fixture-source")
        self.assertEqual("STALE_INPUT", context.exception.code)

    def test_apply_rejects_an_unapproved_hash_without_writing_and_preserves_body_bytes(self):
        module = self.module()
        path = self.write_issue("2026-08-21-001-body.md", issue_text() + b"\xff body bytes\n---\nstatus: prose\n")
        body = module.parse_document(path).body
        (self.issues / "_open-issues.md").write_text("# Open issues\n")
        manifest = module.build_migration_manifest(self.root, "fixture-source")
        manifest_path = self.root / "migration.json"
        module.write_migration_manifest(manifest_path, manifest)
        before = path.read_bytes()

        with self.assertRaises(module.IssueError) as context:
            module.apply_migration(self.root, manifest_path, "fixture-source", "0" * 64)
        self.assertEqual("APPROVAL_HASH_MISMATCH", context.exception.code)
        self.assertEqual(before, path.read_bytes())

        approved_sha256 = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
        module.apply_migration(self.root, manifest_path, "fixture-source", approved_sha256)
        after = path.read_bytes()
        self.assertEqual(body, module.parse_document(path).body)
        self.assertEqual(manifest["entries"][0]["expected_after_sha256"], hashlib.sha256(after).hexdigest())

        module.apply_migration(self.root, manifest_path, "fixture-source", approved_sha256)
        self.assertEqual(after, path.read_bytes())


class ReadTests(IssueFixtures):
    def test_version_and_show_unique_compact_id(self):
        self.write_issue("2026-08-21-001-one.md", issue_text())
        version = subprocess.run(["python3", str(SCRIPT), "--version"], cwd=self.root, capture_output=True, text=True)
        self.assertEqual((0, "repository-issues-contract 1\n"), (version.returncode, version.stdout))
        result = subprocess.run(["python3", str(SCRIPT), "show", "2026-08-21-001", "--json"], cwd=self.root, capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("2026-08-21-001-one", result.stdout)


class WriteTests(IssueFixtures):
    def run_issues(self, *arguments):
        return subprocess.run(["python3", str(SCRIPT)] + list(arguments), cwd=self.root, capture_output=True, text=True, check=False)

    def test_create_assigns_the_next_utc_date_sequence_and_active_body(self):
        today = datetime.now(timezone.utc).date().isoformat()
        self.write_issue("%s-001-existing.md" % today, issue_text(date=today))
        result = self.run_issues("create", "--title", "New issue title", "--short-description", "A useful description.", "--type", "chore", "--category", "testing-ci", "--tag", "new-work", "--priority", "medium")
        self.assertEqual(0, result.returncode, result.stderr)
        path = self.issues / ("%s-002-new-issue-title.md" % today)
        document = self.module().parse_document(path)
        self.assertEqual("open", document.metadata["status"])
        self.assertEqual(["new-work"], document.metadata["tags"])
        self.assertEqual([], self.module().validate_document(document, compatibility=False))

    def test_start_close_and_wontfix_enforce_lifecycle_rules(self):
        open_path = self.write_issue("2026-08-21-001-open.md", issue_text())
        start = self.run_issues("start", "2026-08-21-001")
        self.assertEqual(0, start.returncode, start.stderr)
        self.assertEqual("in-progress", self.module().parse_document(open_path).metadata["status"])
        before = open_path.read_bytes()
        self.assertEqual(2, self.run_issues("start", "2026-08-21-001").returncode)
        self.assertEqual(before, open_path.read_bytes())
        close = self.run_issues("close", "2026-08-21-001", "--resolution", "Implemented and verified.")
        self.assertEqual(0, close.returncode, close.stderr)
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

    def test_invalid_transitions_and_protected_edits_preserve_bytes(self):
        path = self.write_issue("2026-08-21-001-open.md", issue_text())
        cases = [
            ("close", "2026-08-21-001", "--resolution", "Not started."),
            ("wontfix", "2026-08-21-001", "--rationale", ""),
            ("edit", "2026-08-21-001", "--status", "done"),
            ("edit", "2026-08-21-001", "--date", "2026-08-22"),
            ("edit", "2026-08-21-001", "--closed", "2026-08-22"),
            ("edit", "2026-08-21-001-open", "--title", "Renamed file input"),
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

    def test_edit_changes_only_allowed_metadata_and_rejects_terminal_issues(self):
        path = self.write_issue("2026-08-21-001-edit.md", issue_text())
        result = self.run_issues("edit", "2026-08-21-001", "--title", "Edited title", "--tag", "one", "--tag", "two", "--parent-plan", "docs/plans/example.md")
        self.assertEqual(0, result.returncode, result.stderr)
        document = self.module().parse_document(path)
        self.assertEqual("Edited title", document.metadata["title"])
        self.assertEqual(["one", "two"], document.metadata["tags"])
        self.assertEqual("docs/plans/example.md", document.metadata["parent-plan"])

        terminal = self.write_issue("2026-08-21-002-done.md", issue_text(status="done", closed="2026-08-21") + b"\n## Why this exists\n\nReason.\n\n## Resolution\n\nDone.\n")
        before = terminal.read_bytes()
        rejected = self.run_issues("edit", "2026-08-21-002", "--title", "No change")
        self.assertEqual(2, rejected.returncode)
        self.assertEqual(before, terminal.read_bytes())


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
        for command in ("list", "show", "search", "create", "start", "edit", "close", "wontfix", "validate", "migrate"):
            self.assertIn(command, contents)
        self.assertIn("--compatibility", contents)
        self.assertIn("approval", contents.lower())
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
