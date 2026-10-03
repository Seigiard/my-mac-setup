# /// script
# requires-python = ">=3.10"
# dependencies = ["markdown-it-py==4.0.0", "mdit-py-plugins==0.5.0", "pypdf==6.1.1"]
# ///
"""Build deterministic, source-addressed document indexes."""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from markdown_it import MarkdownIt
from mdit_py_plugins.front_matter import front_matter_plugin
from pypdf import PdfReader


FORMAT = "document-map v1"
PARSER = MarkdownIt("commonmark").use(front_matter_plugin)


def label(text):
    return " ".join(text.split())


def inline_text(token):
    return "".join(
        inline_text(child) if child.type == "image" else
        " " if child.type in ("softbreak", "hardbreak") else
        child.content if child.type in ("text", "code_inline") else ""
        for child in (token.children or [])
    )


def sections(headings, total, unit):
    """A parent owns its descendants. PDF boundary pages may overlap."""
    result = []
    stack = []
    for index, (level, title, start) in enumerate(headings):
        end = total
        for next_level, _, next_start in headings[index + 1:]:
            if next_level <= level:
                end = next_start - (unit == "lines")
                break
        while stack and stack[-1] >= level:
            stack.pop()
        result.append(f"{'  ' * len(stack)}{label(title)} — {unit} {start}–{end}")
        stack.append(level)
    return result


def markdown_map(data):
    text = data.decode("utf-8-sig")
    # CommonMark normalizes CRLF and CR before assigning source line numbers.
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    total = text.count("\n") + bool(text and not text.endswith("\n"))
    tokens = PARSER.parse(text)
    headings = []
    body_start = 1
    for index, token in enumerate(tokens):
        if token.type == "front_matter":
            body_start = token.map[1] + 1
        if token.type == "heading_open":
            headings.append((int(token.tag[1:]), inline_text(tokens[index + 1]), token.map[0] + 1))
    if not total:
        return total, ["Empty document"], []
    if not headings:
        return total, [f"Document — lines 1–{total}"], ["No headings"]
    rows = sections(headings, total, "lines")
    first = headings[0][2]
    if any(line.strip() for line in text.split("\n")[body_start - 1:first - 1]):
        rows.insert(0, f"Preamble — lines {body_start}–{first - 1}")
    return total, rows, []


def pdf_map(data):
    reader = PdfReader(io.BytesIO(data))
    if reader.is_encrypted and not reader.decrypt(""):
        raise ValueError("PDF needs a password")
    total = len(reader.pages)
    headings = []

    def visit(items, level=1):
        for item in items:
            if isinstance(item, list):
                visit(item, level + 1)
            else:
                page = reader.get_destination_page_number(item)
                if page is None or not 0 <= page < total:
                    raise ValueError("Outline destination is not a local page")
                headings.append((level, item.title, page + 1))

    visit(reader.outline)
    if not headings:
        return total, ["No outline"], ["No outline; extract structured Markdown separately, then index it"]
    if any(b[2] < a[2] for a, b in zip(headings, headings[1:])):
        raise ValueError("Outline pages are out of order; cannot infer section ranges")
    rows = sections(headings, total, "pages")
    if headings[0][2] > 1:
        rows.insert(0, f"Preamble — pages 1–{headings[0][2]}")
    return total, rows, []


def render(path, data):
    unit = "lines" if path.suffix.lower() == ".md" else "pages"
    total, rows, warnings = markdown_map(data) if unit == "lines" else pdf_map(data)
    header = [FORMAT, f"Source: {json.dumps(path.name, ensure_ascii=False)}",
              f"SHA256: {hashlib.sha256(data).hexdigest()}", f"Total {unit}: {total}"]
    return "\n".join(header + [""] + rows) + "\n", warnings


def current(path, data, target):
    if not target.is_file():
        return False
    with target.open(encoding="utf-8") as stream:
        header = [stream.readline().rstrip("\n") for _ in range(3)]
    return header == [FORMAT, f"Source: {json.dumps(path.name, ensure_ascii=False)}",
                      f"SHA256: {hashlib.sha256(data).hexdigest()}"]


def write_atomic(target, text):
    name = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=target.parent,
                                         prefix=f".{target.name}.", delete=False) as stream:
            name = stream.name
            stream.write(text)
        os.replace(name, target)
    finally:
        if name and os.path.exists(name):
            os.unlink(name)


def ignored(directory, paths):
    """Ask Git in batches, including directories so ignored trees are pruned."""
    if not paths:
        return set()
    probe = subprocess.run(["git", "-C", str(directory), "rev-parse", "--is-inside-work-tree"],
                           capture_output=True)
    if probe.returncode:
        # A normal non-repository is supported; other failures must remain visible.
        if b"not a git repository" in probe.stderr:
            return set()
        raise ValueError(probe.stderr.decode(errors="replace").strip())
    result = subprocess.run(["git", "-C", str(directory), "check-ignore", "--no-index", "-z", "--stdin"],
                            input=b"\0".join(os.fsencode(p) for p in paths) + b"\0", capture_output=True)
    if result.returncode not in (0, 1):
        raise ValueError(result.stderr.decode(errors="replace").strip())
    return {Path(os.fsdecode(p)) for p in result.stdout.split(b"\0") if p}


def discover(root):
    def walk_error(error):
        raise error

    for directory, dirs, files in os.walk(root, onerror=walk_error):
        base = Path(directory)
        candidates = [base / name for name in dirs + files
                      if not name.startswith(".") and not (base / name).is_symlink()]
        excluded = ignored(base, candidates)
        dirs[:] = sorted(name for name in dirs if base / name in candidates and base / name not in excluded)
        for name in sorted(files):
            path = base / name
            if path in candidates and path not in excluded and path.suffix.lower() in (".md", ".pdf"):
                yield path


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path, help="Markdown/PDF files or directories")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--stdout", action="store_true", help="print one file's index without writing")
    mode.add_argument("--check", action="store_true", help="check source hashes without writing; stale/missing exits 1")
    args = parser.parse_args(argv)
    if args.stdout and (len(args.paths) != 1 or args.paths[0].is_dir()):
        parser.error("--stdout requires one file")
    counts = dict(processed=0, updated=0, unchanged=0, stale=0, warnings=0, errors=0)
    seen = set()

    def process(path):
        if path in seen:
            return
        seen.add(path)
        try:
            if path.is_symlink():
                raise ValueError("Symbolic links are not supported")
            if path.suffix.lower() not in (".md", ".pdf"):
                raise ValueError("Expected .md or .pdf")
            data = path.read_bytes()
            counts["processed"] += 1
            target = path.with_name(path.name + ".toc")
            if target.is_symlink():
                raise ValueError("Index is a symbolic link")
            if args.check:
                fresh = current(path, data, target)
                counts["unchanged" if fresh else "stale"] += 1
                if not fresh:
                    print(f"STALE {str(path)!r}", file=sys.stderr)
                return
            text, warnings = render(path, data)
            for warning in warnings:
                counts["warnings"] += 1
                print(f"WARNING {str(path)!r}: {warning}", file=sys.stderr)
            if args.stdout:
                sys.stdout.write(text)
            elif target.is_file() and target.read_text(encoding="utf-8") == text:
                counts["unchanged"] += 1
            else:
                write_atomic(target, text)
                counts["updated"] += 1
        except Exception as error:
            counts["errors"] += 1
            print(f"ERROR {str(path)!r}: {error}", file=sys.stderr)

    for supplied in args.paths:
        root = Path(os.path.abspath(supplied))
        try:
            if root.is_dir() and not root.is_symlink():
                for path in discover(root):
                    process(path)
            else:
                process(root)
        except Exception as error:
            counts["errors"] += 1
            print(f"ERROR {str(root)!r}: {error}", file=sys.stderr)
    print("Summary: " + ", ".join(f"{key}={value}" for key, value in counts.items()), file=sys.stderr)
    return 1 if counts["errors"] or counts["stale"] else 0


if __name__ == "__main__":
    sys.exit(main())
