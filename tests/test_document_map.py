"""CLI behavior against the user-approved source-range contract."""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "home/private_dot_agents/skills/document-map/scripts/document_map.py"
FIXTURES = ROOT / "tests/fixtures/document-map"


def pdf_bytes(outline=True, backwards=False):
    """Five physical pages; parent and child at page 2, next peer at page 4."""
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R" + (b" /Outlines 8 0 R" if outline else b"") + b" >>",
        b"<< /Type /Pages /Count 5 /Kids [3 0 R 4 0 R 5 0 R 6 0 R 7 0 R] >>",
    ]
    objects.extend([b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>"] * 5)
    if outline:
        objects.extend([
            b"<< /Type /Outlines /First 9 0 R /Last 11 0 R /Count 3 >>",
            b"<< /Title (Start) /Parent 8 0 R /Dest [4 0 R /Fit] /Next 11 0 R /First 10 0 R /Last 10 0 R /Count 1 >>",
            b"<< /Title (Child) /Parent 9 0 R /Dest [4 0 R /Fit] >>",
            b"<< /Title (End) /Parent 8 0 R /Prev 9 0 R /Dest [" + (b"3" if backwards else b"6") + b" 0 R /Fit] >>",
        ])
    data = b"%PDF-1.4\n"
    offsets = [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data += f"{index} 0 obj\n".encode() + obj + b"\nendobj\n"
    xref = len(data)
    data += f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode()
    data += b"".join(f"{offset:010d} 00000 n \n".encode() for offset in offsets[1:])
    data += f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return data


class DocumentMapTests(unittest.TestCase):
    def setUp(self):
        if not shutil.which("uv"):
            self.fail("document-map contract tests require uv on PATH")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)

    def run_cli(self, *args, status=0):
        result = subprocess.run(["uv", "run", "--script", str(SCRIPT), *map(str, args)],
                                capture_output=True, text=True, cwd=self.base)
        self.assertEqual(result.returncode, status, result.stderr)
        return result

    def document(self, name, data):
        path = self.base / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def body(self, output):
        return output.split("\n\n", 1)[1]

    def test_markdown_fixture_ranges(self):
        # given: hand-counted headings, fences, Unicode, and EOF boundaries
        for name in ("ordinary", "formatting", "plain"):
            with self.subTest(name=name):
                # when
                result = self.run_cli(FIXTURES / f"{name}.md", "--stdout")
                # then
                self.assertEqual(self.body(result.stdout), (FIXTURES / f"{name}.expected.toc").read_text())

    def test_empty_and_single_heading_without_final_newline(self):
        # given
        for data, expected in [(b"", "Empty document\n"), (b"# Only\nbody", "Only — lines 1–2\n"),
                               (b"# A\r\nbody\r\n## B\r\nend", "A — lines 1–4\n  B — lines 3–4\n")]:
            with self.subTest(data=data):
                path = self.document("input.md", data)
                # when
                result = self.run_cli(path, "--stdout")
                # then
                self.assertEqual(self.body(result.stdout), expected)

    def test_hash_check_detects_edits_and_generation_repairs_staleness(self):
        # given
        path = self.document("doc.md", b"# First\ntext\n")
        self.run_cli(path, "--check", status=1)
        # when
        self.run_cli(path)
        index = Path(str(path) + ".toc")
        before = index.stat().st_mtime_ns
        self.run_cli(path, "--check")
        self.run_cli(path)
        # then
        self.assertEqual(index.stat().st_mtime_ns, before)
        self.assertEqual(index.read_text().splitlines()[2], "SHA256: " + hashlib.sha256(path.read_bytes()).hexdigest())
        path.write_text("intro\n# First\ntext\n")
        self.run_cli(path, "--check", status=1)
        self.run_cli(path)
        self.run_cli(path, "--check")
        self.assertEqual(self.body(index.read_text()), "Preamble — lines 1–1\nFirst — lines 2–3\n")

    def test_stdout_does_not_create_sidecar(self):
        # given
        path = self.document("only.md", b"# Only")
        # when
        self.run_cli(path, "--stdout")
        # then
        self.assertEqual(sorted(p.name for p in self.base.iterdir()), ["only.md"])

    def test_pdf_ranges_overlap_and_keep_child(self):
        # given
        path = self.document("manual.pdf", pdf_bytes())
        # when
        result = self.run_cli(path, "--stdout")
        # then
        self.assertEqual(self.body(result.stdout), "Preamble — pages 1–2\nStart — pages 2–4\n  Child — pages 2–4\nEnd — pages 4–5\n")

    def test_no_outline_is_a_current_warned_index(self):
        # given
        path = self.document("manual.pdf", pdf_bytes(outline=False))
        # when
        result = self.run_cli(path)
        self.run_cli(path, "--check")
        # then
        self.assertEqual(self.body(Path(str(path) + ".toc").read_text()), "No outline\n")
        self.assertEqual(result.stderr.splitlines(), [
            f"WARNING {str(path)!r}: No outline; extract structured Markdown separately, then index it",
            "Summary: processed=1, updated=1, unchanged=0, stale=0, warnings=1, errors=0",
        ])

    def test_backward_outline_fails_without_replacing_index(self):
        # given: valid control reaches PDF success before the invalid destination order
        path = self.document("manual.pdf", pdf_bytes())
        self.run_cli(path)
        index = Path(str(path) + ".toc")
        before = index.read_bytes()
        path.write_bytes(pdf_bytes(backwards=True))
        # when
        result = self.run_cli(path, status=1)
        # then
        self.assertEqual(result.stderr.splitlines()[0], f"ERROR {str(path)!r}: Outline pages are out of order; cannot infer section ranges")
        self.assertEqual(index.read_bytes(), before)

    def test_batch_continues_after_bad_input(self):
        # given
        bad = self.document("bad.pdf", b"broken")
        good = self.document("good.md", b"# Fine")
        # when
        result = self.run_cli(bad, good, status=1)
        # then
        self.assertEqual(self.body(Path(str(good) + ".toc").read_text()), "Fine — lines 1–1\n")
        self.assertEqual(result.stderr.splitlines()[-1], "Summary: processed=2, updated=1, unchanged=0, stale=0, warnings=0, errors=1")

    def test_directory_filters_and_explicit_ignored_file(self):
        # given
        git = subprocess.run(["git", "init", "-q", str(self.base)], capture_output=True)
        self.assertEqual(git.returncode, 0, git.stderr)
        self.document(".gitignore", b"ignored/\n")
        self.document("visible.md", b"# Visible")
        self.document("nested/other.MD", b"# Nested")
        ignored = self.document("ignored/secret.md", b"# Ignored")
        self.document(".hidden/hidden.md", b"# Hidden")
        (self.base / "linked.md").symlink_to(self.base / "visible.md")
        (self.base / "linked-dir").symlink_to(self.base / "nested", target_is_directory=True)
        # when
        self.run_cli(self.base)
        # then
        self.assertEqual(sorted(str(p.relative_to(self.base)) for p in self.base.rglob("*.toc")),
                         ["nested/other.MD.toc", "visible.md.toc"])
        self.run_cli(ignored)
        self.assertEqual(self.body(Path(str(ignored) + ".toc").read_text()), "Ignored — lines 1–1\n")

    def test_non_git_directory_and_duplicate_arguments(self):
        # given
        path = self.document("doc.md", b"# Doc")
        # when
        result = self.run_cli(self.base, path)
        # then
        self.assertEqual(result.stderr, "Summary: processed=1, updated=1, unchanged=0, stale=0, warnings=0, errors=0\n")

    def test_argument_and_symlink_rejections(self):
        # given
        path = self.document("doc.md", b"# Doc")
        target = self.document("important.txt", b"preserve me")
        Path(str(path) + ".toc").symlink_to(target)
        # when
        self.run_cli(path, status=1)
        self.run_cli(self.base, "--stdout", status=2)
        self.run_cli(path, "--check", "--stdout", status=2)
        # then
        self.assertEqual(target.read_bytes(), b"preserve me")

    def test_launcher_finds_skill_under_disposable_home(self):
        # given: the installed layout, with a document path containing spaces
        skill = self.base / ".agents/skills/document-map"
        skill.parent.mkdir(parents=True)
        skill.symlink_to(SCRIPT.parent.parent, target_is_directory=True)
        path = self.document("my notes.md", b"# Notes")
        # when
        result = subprocess.run(
            ["sh", str(ROOT / "home/dot_local/bin/executable_document-map"), str(path), "--stdout"],
            env={**os.environ, "HOME": str(self.base)}, capture_output=True, text=True,
        )
        # then
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.body(result.stdout), "Notes — lines 1–1\n")


if __name__ == "__main__":
    unittest.main()
