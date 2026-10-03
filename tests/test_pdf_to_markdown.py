"""Evidence preparation must preserve page identity, text, and earlier work."""

import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "home/private_dot_agents/skills/pdf-to-markdown/scripts/prepare_pages.py"


def pdf_fixture(bad_middle=False):
    """Three visible physical pages, with text values specified by the caller contract."""
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Count 3 /Kids [3 0 R 5 0 R 7 0 R] >>",
    ]
    for index, text in enumerate(("First: 1d6+2", "Second: -1", "Third: 10+")):
        box = b"[0 0 0 0]" if bad_middle and index == 1 else b"[0 0 200 100]"
        objects.append(b"<< /Type /Page /Parent 2 0 R /MediaBox " + box
                       + b" /Resources << /Font << /F1 9 0 R >> >> /Contents "
                       + str(4 + 2 * index).encode() + b" 0 R >>")
        stream = f"BT /F1 12 Tf 10 50 Td ({text}) Tj ET".encode()
        objects.append(f"<< /Length {len(stream)} >>\nstream\n".encode() + stream + b"\nendstream")
    objects.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    data = b"%PDF-1.4\n"
    offsets = []
    for number, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data += f"{number} 0 obj\n".encode() + obj + b"\nendobj\n"
    xref = len(data)
    data += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
    data += b"".join(f"{offset:010d} 00000 n \n".encode() for offset in offsets)
    data += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return data


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.pdf = self.base / "source book.pdf"
        self.pdf.write_bytes(pdf_fixture())
        self.out = self.base / "batch"

    def run_cli(self, *args, status=0):
        result = subprocess.run(["uv", "run", "--script", str(SCRIPT), str(self.pdf), *map(str, args)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, status, result.stderr)
        return result

    def test_info_uses_real_physical_count_and_source_hash_without_outputs(self):
        # given
        digest = hashlib.sha256(self.pdf.read_bytes()).hexdigest()
        # when
        result = self.run_cli("--info")
        # then
        info = json.loads(result.stdout)
        self.assertEqual((info["total_pages"], info["source_sha256"]), (3, digest))
        self.assertEqual(list(self.base.iterdir()), [self.pdf])

    def test_selection_keeps_physical_identity_numeric_text_and_rendered_image(self):
        # given: noncontiguous pages, duplicate selection, spaces in paths
        before = self.pdf.read_bytes()
        # when
        self.run_cli("--pages", "3,1,3", "--out", self.out, "--dpi", "150")
        # then
        manifest = json.loads((self.out / "manifest.json").read_text())
        self.assertEqual(manifest["requested_pages"], [1, 3])
        self.assertEqual([(p["page"], p["status"]) for p in manifest["pages"]], [(1, "prepared"), (3, "prepared")])
        self.assertEqual((self.out / "page-0001.native.txt").read_text(), "First: 1d6+2")
        self.assertEqual((self.out / "page-0003.native.txt").read_text(), "Third: 10+")
        self.assertEqual((self.out / "page-0001.png").read_bytes()[:8], b"\x89PNG\r\n\x1a\n")
        words = json.loads((self.out / "page-0003.words.json").read_text())
        self.assertEqual([w["text"] for w in words], ["Third:", "10+"])
        self.assertEqual(words[0]["x0"], 10)
        self.assertEqual(self.pdf.read_bytes(), before)

    def test_existing_evidence_is_not_overwritten(self):
        # given: valid preparation control
        self.run_cli("--pages", "1", "--out", self.out, "--dpi", "150")
        before = {p.name: p.read_bytes() for p in self.out.iterdir()}
        # when
        self.run_cli("--pages", "2", "--out", self.out, status=1)
        # then
        self.assertEqual({p.name: p.read_bytes() for p in self.out.iterdir()}, before)

    def test_invalid_selections_do_not_leave_partial_directories(self):
        # given / when
        for pages in ("0", "4", "3-1", "1-2-3", "1,", "x"):
            with self.subTest(pages=pages):
                self.run_cli("--pages", pages, "--out", self.out, status=2)
        # then
        self.assertEqual(list(self.base.iterdir()), [self.pdf])

    def test_bad_page_records_failure_and_later_page_still_completes(self):
        # given: one zero-area page between two renderable controls
        self.pdf.write_bytes(pdf_fixture(bad_middle=True))
        # when
        self.run_cli("--pages", "1-3", "--out", self.out, "--dpi", "150", status=1)
        # then
        manifest = json.loads((self.out / "manifest.json").read_text())
        self.assertEqual(manifest["status"], "failed")
        self.assertEqual([(p["page"], p["status"]) for p in manifest["pages"]],
                         [(1, "prepared"), (2, "failed"), (3, "prepared")])
        self.assertEqual((self.out / "page-0003.native.txt").read_text(), "Third: 10+")


if __name__ == "__main__":
    unittest.main()
