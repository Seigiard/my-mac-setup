#!/usr/bin/env python3
"""Assemble a page from the render kit.

    python3 assemble.py draft.html -o page.html

Replaces three markers with the kit's files from this directory, so a page
carries the kit inside itself and works from disk, by mail, or on a host:

    <!-- kit: head -->        head.html: kit-build meta, charset, viewport, base layer (tokens and bare-element rules)
    <!-- kit: components -->  components.css wrapped in a <style>
    <!-- kit: scripts -->     scripts.html: the highlighter, annotation layer, Mermaid, term, contents and lightbox scripts

An <img src> that names a local file, relative to the draft, becomes a data
URI, so the draft stays small enough to read and edit while the page carries
its frames. Remote and data sources stay as written.

A marker the draft does not carry is skipped; a missing kit file or image
stops the run with exit status 1, so a page is never written half-built.

Headings h1-h4 that share their text and lack an id print a warning: the
annotation layer can name them only by position, so each needs an id.
"""
import argparse
import base64
import hashlib
import mimetypes
import re
import sys
from collections import Counter
from html.parser import HTMLParser
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


class Headings(HTMLParser):
    """Collects each h1-h4 heading's whitespace-collapsed text and whether it has an id."""

    TAGS = {"h1", "h2", "h3", "h4"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.found = []
        self.current = None

    def handle_starttag(self, tag, attrs):
        if tag in self.TAGS and self.current is None:
            self.current = (bool(dict(attrs).get("id")), [])

    def handle_endtag(self, tag):
        if tag in self.TAGS and self.current is not None:
            has_id, parts = self.current
            self.found.append((" ".join("".join(parts).split()), has_id))
            self.current = None

    def handle_data(self, data):
        if self.current is not None:
            self.current[1].append(data)


def repeated_headings(html):
    parser = Headings()
    parser.feed(html)
    parser.close()
    counts = Counter(text for text, _ in parser.found)
    return sorted({text for text, has_id in parser.found if not has_id and counts[text] > 1})


def assemble(html, base, build_id=None):
    for marker, load in MARKERS.items():
        if marker in html:
            replacement = load()
            if marker == "<!-- kit: head -->" and build_id is not None:
                replacement = f'<meta name="kit-build" content="{build_id}">\n' + replacement
            html = html.replace(marker, replacement)
    return inline_images(html, base)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("draft", help="HTML draft carrying the kit markers")
    parser.add_argument("-o", "--output", help="write here instead of stdout")
    args = parser.parse_args()
    try:
        draft = Path(args.draft)
        draft_bytes = draft.read_bytes()
        result = assemble(
            draft_bytes.decode("utf-8"),
            draft.parent,
            hashlib.sha256(draft_bytes).hexdigest()[:7],
        )
    except FileNotFoundError as error:
        print(f"assemble: missing file: {error.filename}", file=sys.stderr)
        return 1
    for text in repeated_headings(draft_bytes.decode("utf-8")):
        print(f'assemble: warning: several headings read "{text}" and one has no id; give each an id', file=sys.stderr)
    if args.output:
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(result, encoding="utf-8")
    else:
        sys.stdout.write(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
