"""Render kit assembly: a draft becomes a page that works from disk."""

import base64
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
KIT = ROOT / "home/private_dot_claude/shared/render-kit"
ASSEMBLE = KIT / "assemble.py"
PIXEL = base64.b64decode("R0lGODlhAQABAAAAACw=")


def assemble(draft):
    return subprocess.run(
        [sys.executable, str(ASSEMBLE), str(draft)],
        capture_output=True, text=True, check=False,
    )


class LocalImages(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)
        (self.dir / "frames").mkdir()
        (self.dir / "frames/one.gif").write_bytes(PIXEL)

    def test_local_image_is_inlined_as_a_data_uri(self):
        # #given a draft whose frame points at a file beside it
        draft = self.dir / "page.html"
        draft.write_text('<figure><img src="frames/one.gif" alt="one"></figure>', encoding="utf-8")
        # #when
        result = assemble(draft)
        # #then
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            '<figure><img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" alt="one"></figure>',
        )

    def test_remote_and_data_sources_stay_as_written(self):
        # #given
        html = ('<img src="https://example.com/a.png">'
                '<img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=">')
        draft = self.dir / "page.html"
        draft.write_text(html, encoding="utf-8")
        # #when
        result = assemble(draft)
        # #then
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, html)

    def test_image_is_found_whatever_the_attribute_markup(self):
        # #given an unquoted src, a '>' inside an earlier attribute, and a data-src that is not the image's source
        draft = self.dir / "page.html"
        draft.write_text(
            '<img src=frames/one.gif alt=one>'
            '<img alt="Settings > Orders" src="frames/one.gif">'
            '<img data-src="frames/missing.png" src="https://example.com/a.png">',
            encoding="utf-8",
        )
        # #when
        result = assemble(draft)
        # #then
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            '<img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" alt=one>'
            '<img alt="Settings > Orders" src="data:image/gif;base64,R0lGODlhAQABAAAAACw=">'
            '<img data-src="frames/missing.png" src="https://example.com/a.png">',
        )

    def test_output_goes_to_a_directory_that_does_not_exist_yet(self):
        # #given a cycle's first build, before build/ exists
        draft = self.dir / "page.html"
        draft.write_text('<img src="frames/one.gif">', encoding="utf-8")
        out = self.dir / "build/page.html"
        # #when
        result = subprocess.run(
            [sys.executable, str(ASSEMBLE), str(draft), "-o", str(out)],
            capture_output=True, text=True, check=False,
        )
        # #then
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(out.read_text(encoding="utf-8"), '<img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=">')

    def test_missing_image_stops_the_run(self):
        # #given a frame whose file was never captured, next to one that was
        draft = self.dir / "page.html"
        draft.write_text('<img src="frames/one.gif"><img src="frames/two.png">', encoding="utf-8")
        out = self.dir / "built.html"
        # #when
        result = subprocess.run(
            [sys.executable, str(ASSEMBLE), str(draft), "-o", str(out)],
            capture_output=True, text=True, check=False,
        )
        # #then
        self.assertEqual(result.returncode, 1)
        self.assertIn("frames/two.png", result.stderr)
        self.assertFalse(out.exists())


class ShippedPages(unittest.TestCase):
    """Every page an agent starts from assembles into a styled page."""

    PAGES = [
        KIT / "gallery.html",
        *(ROOT / "home/private_dot_claude/shared/pf-cycle-pages" / name for name in ("issue.html", "research.html", "spec.html", "demo.html")),
        ROOT / "home/private_dot_agents/skills/explain-diff-html/references/template.html",
    ]

    def test_each_page_assembles_with_every_marker_replaced(self):
        for page in self.PAGES:
            with self.subTest(page=page.name):
                # #when
                result = assemble(page)
                # #then
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("<!-- kit:", result.stdout)
                for part in ("head.html", "components.css", "scripts.html"):
                    self.assertIn((KIT / part).read_text(encoding="utf-8").rstrip(), result.stdout, part)
                meta_tags = [
                    tag for tag in re.findall(r"<meta\b[^>]*>", result.stdout)
                    if re.search(r"\bname=(?:\"kit-build\"|'kit-build')", tag)
                ]
                self.assertEqual(len(meta_tags), 1)
                content = re.search(r"\bcontent=(?:\"([^\"]*)\"|'([^']*)')", meta_tags[0])
                self.assertIsNotNone(content)
                self.assertEqual(
                    next(value for value in content.groups() if value is not None),
                    hashlib.sha256(page.read_bytes()).hexdigest()[:7],
                )


class KitBuild(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)

    def test_head_marker_produces_one_build_meta_with_the_draft_hash(self):
        # #given a draft that asks the assembler to insert the head
        draft = self.dir / "page.html"
        draft.write_text(
            "<html><head><!-- kit: head --></head><body>one</body></html>",
            encoding="utf-8",
        )
        expected = "0d957ea"
        # #when
        result = assemble(draft)
        # #then
        self.assertEqual(result.returncode, 0, result.stderr)
        meta_tags = [
            tag for tag in re.findall(r"<meta\b[^>]*>", result.stdout)
            if re.search(r"\bname=(?:\"kit-build\"|'kit-build')", tag)
        ]
        self.assertEqual(len(meta_tags), 1)
        content = re.search(r"\bcontent=(?:\"([^\"]*)\"|'([^']*)')", meta_tags[0])
        self.assertIsNotNone(content)
        self.assertEqual(
            next(value for value in content.groups() if value is not None),
            expected,
        )

    def test_build_meta_is_stable_until_the_draft_bytes_change(self):
        # #given a draft with the head marker
        draft = self.dir / "page.html"
        first_draft = "<html><head><!-- kit: head --></head><body>a</body></html>"
        draft.write_text(first_draft, encoding="utf-8")
        expected_first = hashlib.sha256(draft.read_bytes()).hexdigest()[:7]
        # #when it assembles twice, then one byte changes and it assembles again
        first = assemble(draft)
        second = assemble(draft)
        draft.write_text(first_draft.replace(">a<", ">b<"), encoding="utf-8")
        expected_changed = hashlib.sha256(draft.read_bytes()).hexdigest()[:7]
        changed = assemble(draft)
        # #then each result reports the hash of the exact draft bytes it read
        for result, expected in ((first, expected_first), (second, expected_first), (changed, expected_changed)):
            self.assertEqual(result.returncode, 0, result.stderr)
            matches = re.findall(
                r'<meta\s+name="kit-build"\s+content="([0-9a-f]{7})">',
                result.stdout,
            )
            self.assertEqual(matches, [expected])
        self.assertNotEqual(expected_first, expected_changed)


class RepeatedHeadings(unittest.TestCase):
    """A heading that repeats another's text needs an id, or annotations can name it only by position."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)

    def test_repeated_heading_text_without_an_id_warns_and_still_assembles(self):
        # #given two sections that each carry an "Evidence" heading without an id
        draft = self.dir / "page.html"
        draft.write_text(
            "<body><h2 id=a>A</h2><h3>Evidence</h3><p>x</p>"
            "<h2 id=b>B</h2><h3> Evidence </h3><p>y</p></body>",
            encoding="utf-8",
        )
        # #when
        result = assemble(draft)
        # #then
        self.assertEqual(result.returncode, 0)
        self.assertEqual(
            result.stderr,
            'assemble: warning: several headings read "Evidence" and one has no id; give each an id\n',
        )

    def test_repeated_heading_text_with_ids_assembles_silently(self):
        # #given the same headings, each with its own id
        draft = self.dir / "page.html"
        draft.write_text(
            "<body><h2 id=a>A</h2><h3 id=a-evidence>Evidence</h3><p>x</p>"
            "<h2 id=b>B</h2><h3 id=b-evidence>Evidence</h3><p>y</p></body>",
            encoding="utf-8",
        )
        # #when
        result = assemble(draft)
        # #then
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
