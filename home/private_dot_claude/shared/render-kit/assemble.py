#!/usr/bin/env python3
"""Assemble a page from the render kit.

    python3 assemble.py draft.html -o page.html

Replaces three markers with the kit's files from this directory, so a page
carries the kit inside itself and works from disk, by mail, or on a host:

    <!-- kit: head -->        head.html: charset, viewport, base layer (tokens and bare-element rules)
    <!-- kit: components -->  components.css wrapped in a <style>
    <!-- kit: scripts -->     scripts.html: the highlighter, Mermaid, term, contents and lightbox scripts

An <img src> that names a local file, relative to the draft, becomes a data
URI, so the draft stays small enough to read and edit while the page carries
its frames. Remote and data sources stay as written.

A marker the draft does not carry is skipped; a missing kit file or image
stops the run with exit status 1, so a page is never written half-built.
"""
import argparse
import base64
import mimetypes
import re
import sys
from pathlib import Path

KIT = Path(__file__).resolve().parent
MARKERS = {
    "<!-- kit: head -->": lambda: (KIT / "head.html").read_text(encoding="utf-8").rstrip(),
    "<!-- kit: components -->": lambda: "<style>\n" + (KIT / "components.css").read_text(encoding="utf-8").rstrip() + "\n</style>",
    "<!-- kit: scripts -->": lambda: (KIT / "scripts.html").read_text(encoding="utf-8").rstrip(),
}


IMG_TAG = re.compile(r"""<img\b(?:[^>"']|"[^"]*"|'[^']*')*>""", re.IGNORECASE)
SRC_ATTR = re.compile(r"""(?<![\w-])(src\s*=\s*)(?:"([^"]*)"|'([^']*)'|([^\s>"']+))""", re.IGNORECASE)
NOT_LOCAL = re.compile(r"^(?:[a-z][a-z0-9+.-]*:|//|#)", re.IGNORECASE)
COMMENT = re.compile(r"(<!--.*?-->)", re.DOTALL)


def inline_images(html, base):
    def inline_src(match):
        prefix = match.group(1)
        src = next(value for value in match.groups()[1:] if value is not None)
        if NOT_LOCAL.match(src):
            return match.group(0)
        path = base / src
        kind = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        data = base64.b64encode(path.read_bytes()).decode("ascii")
        return f'{prefix}"data:{kind};base64,{data}"'

    def inline(match):
        return SRC_ATTR.sub(inline_src, match.group(0), count=1)
    # A template's slot comments show <img> markup as an example; only real elements are inlined.
    parts = COMMENT.split(html)
    return "".join(part if index % 2 else IMG_TAG.sub(inline, part) for index, part in enumerate(parts))


def assemble(html, base):
    for marker, load in MARKERS.items():
        if marker in html:
            html = html.replace(marker, load())
    return inline_images(html, base)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("draft", help="HTML draft carrying the kit markers")
    parser.add_argument("-o", "--output", help="write here instead of stdout")
    args = parser.parse_args()
    try:
        draft = Path(args.draft)
        result = assemble(draft.read_text(encoding="utf-8"), draft.parent)
    except FileNotFoundError as error:
        print(f"assemble: missing file: {error.filename}", file=sys.stderr)
        return 1
    if args.output:
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(result, encoding="utf-8")
    else:
        sys.stdout.write(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
