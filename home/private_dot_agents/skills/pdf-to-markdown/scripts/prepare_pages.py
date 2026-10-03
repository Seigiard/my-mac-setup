# /// script
# requires-python = ">=3.10"
# dependencies = ["pdfplumber==0.11.9"]
# ///
"""Prepare page images and raw text evidence for visual PDF reconstruction."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

import pdfplumber


def selected_pages(value, total):
    pages = set()
    for part in value.split(","):
        ends = part.strip().split("-")
        if len(ends) not in (1, 2) or any(not end.isdigit() for end in ends):
            raise ValueError("pages must be numbers or inclusive ranges, such as 1-4,20")
        start, stop = int(ends[0]), int(ends[-1])
        if not 1 <= start <= stop <= total:
            raise ValueError(f"page range {part!r} is outside 1–{total}")
        pages.update(range(start, stop + 1))
    return sorted(pages)


def source_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def save_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pdf", type=Path)
    parser.add_argument("--info", action="store_true", help="print source hash and physical page count")
    parser.add_argument("--pages", help="one-based physical page selection, such as 1-4,20")
    parser.add_argument("--out", type=Path, help="new evidence directory; parent must exist")
    parser.add_argument("--dpi", type=int, choices=(150, 300, 600), default=300)
    parser.add_argument("--ocr", action="store_true", help="also run local Tesseract")
    parser.add_argument("--lang", default="eng", help="Tesseract language, e.g. eng or ukr")
    parser.add_argument("--tessdata", type=Path, help="directory containing Tesseract language packs")
    args = parser.parse_args(argv)
    if args.info and (args.pages or args.out or args.ocr):
        parser.error("--info is separate from page preparation")
    if not args.info and (not args.pages or not args.out):
        parser.error("preparation requires --pages and --out")
    if args.ocr and not shutil.which("tesseract"):
        parser.error("--ocr requires tesseract on PATH")
    try:
        before = source_hash(args.pdf)
        with pdfplumber.open(args.pdf) as pdf:
            manifest = {"source_pdf": str(args.pdf.resolve()), "source_sha256": before,
                        "total_pages": len(pdf.pages), "pdfplumber": pdfplumber.__version__}
            if args.info:
                print(json.dumps(manifest, ensure_ascii=False))
                return 0
            try:
                pages = selected_pages(args.pages, len(pdf.pages))
            except ValueError as error:
                parser.error(str(error))
            # Exclusive creation prevents overwriting a previous run or a symlink.
            args.out.mkdir()
            manifest.update(dpi=args.dpi, ocr=args.ocr, language=args.lang if args.ocr else None,
                            requested_pages=pages, pages=[])
            manifest_path = args.out / "manifest.json"
            save_json(manifest_path, manifest)
            for number in pages:
                record = {"page": number, "status": "preparing", "outputs": {}}
                stem = f"page-{number:04d}"
                page = pdf.pages[number - 1]
                print(f"START page={number}", file=sys.stderr, flush=True)
                try:
                    record.update(width_points=page.width, height_points=page.height)
                    image = args.out / f"{stem}.png"
                    page.to_image(resolution=args.dpi).save(image)
                    record["outputs"]["image"] = image.name
                    native = args.out / f"{stem}.native.txt"
                    native.write_text(page.extract_text() or "", encoding="utf-8")
                    record["outputs"]["native_text"] = native.name
                    words_path = args.out / f"{stem}.words.json"
                    words = page.extract_words(extra_attrs=["fontname", "size"])
                    save_json(words_path, words)
                    record["outputs"]["native_words"] = words_path.name
                    record["native_word_count"] = len(words)
                    if args.ocr:
                        prefix = args.out / f"{stem}.ocr"
                        command = ["tesseract", str(image), str(prefix), "-l", args.lang,
                                   "--dpi", str(args.dpi), "--oem", "1", "--psm", "3"]
                        if args.tessdata:
                            command += ["--tessdata-dir", str(args.tessdata)]
                        command += ["-c", "tessedit_create_txt=1", "-c", "tessedit_create_tsv=1"]
                        result = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, text=True)
                        save_json(args.out / f"{stem}.ocr-command.json",
                                  dict(argv=command, status=result.returncode, stdout=result.stdout, stderr=result.stderr))
                        if result.returncode:
                            raise RuntimeError(f"Tesseract exited {result.returncode}; see {stem}.ocr-command.json")
                        for suffix in ("txt", "tsv"):
                            output = Path(f"{prefix}.{suffix}")
                            if not output.is_file():
                                raise RuntimeError(f"Tesseract did not create {output.name}")
                            record["outputs"][f"ocr_{suffix}"] = output.name
                    record["status"] = "prepared"
                except Exception as error:
                    record.update(status="failed", error=str(error))
                finally:
                    page.close()
                manifest["pages"].append(record)
                save_json(manifest_path, manifest)
                print(f"DONE page={number} status={record['status']}", file=sys.stderr, flush=True)
            changed = source_hash(args.pdf) != before
            manifest["source_unchanged"] = not changed
            if changed:
                manifest["error"] = "Source PDF changed during preparation; discard this batch"
            errors = sum(p["status"] == "failed" for p in manifest["pages"]) + int(changed)
            manifest["status"] = "failed" if errors else "prepared"
            save_json(manifest_path, manifest)
            print(f"Summary: pages={len(pages)}, prepared={sum(p['status'] == 'prepared' for p in manifest['pages'])}, errors={errors}",
                  file=sys.stderr, flush=True)
            return int(bool(errors))
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
