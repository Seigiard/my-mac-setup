#!/usr/bin/env python3
"""Assemble a page from the render kit.

    python3 assemble.py draft.html -o page.html

Replaces three markers with the kit's files from this directory, so a page
carries the kit inside itself and works from disk, by mail, or on a host:

    <!-- kit: head -->        head.html: charset, viewport, stylesheet links, base layer
    <!-- kit: components -->  components.css wrapped in a <style>
    <!-- kit: scripts -->     scripts.html: the highlighter loader

A marker the draft does not carry is skipped; a kit file that is missing
stops the run with exit status 1, so a page is never written half-built.
"""
import argparse
import sys
from pathlib import Path

KIT = Path(__file__).resolve().parent
MARKERS = {
    "<!-- kit: head -->": lambda: (KIT / "head.html").read_text(encoding="utf-8").rstrip(),
    "<!-- kit: components -->": lambda: "<style>\n" + (KIT / "components.css").read_text(encoding="utf-8").rstrip() + "\n</style>",
    "<!-- kit: scripts -->": lambda: (KIT / "scripts.html").read_text(encoding="utf-8").rstrip(),
}


def assemble(html):
    for marker, load in MARKERS.items():
        if marker in html:
            html = html.replace(marker, load())
    return html


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("draft", help="HTML draft carrying the kit markers")
    parser.add_argument("-o", "--output", help="write here instead of stdout")
    args = parser.parse_args()
    try:
        result = assemble(Path(args.draft).read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        print(f"assemble: missing file: {error.filename}", file=sys.stderr)
        return 1
    if args.output:
        Path(args.output).write_text(result, encoding="utf-8")
    else:
        sys.stdout.write(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
