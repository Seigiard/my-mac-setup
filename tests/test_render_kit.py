"""Render kit assembly: a draft becomes a page that works from disk."""

import base64
from pathlib import Path
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
        *(ROOT / "home/private_dot_claude/shared/pf-cycle-pages" / name for name in ("research.html", "spec.html", "demo.html")),
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


if __name__ == "__main__":
    unittest.main()
