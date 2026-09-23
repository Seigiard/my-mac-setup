#!/usr/bin/env python3
"""Put the page's external stylesheets inside the file.

    python3 inject-styles.py page.html               # result on stdout
    python3 inject-styles.py page.html -o out.html

Every <link rel="stylesheet" href="http(s)://…"> becomes a <style> holding
the fetched CSS; a media attribute on the link stays on the style, so the
light and dark themes keep switching. Scripts stay external. Exit status 1
with the URL on stderr when a stylesheet cannot be fetched, so a half-styled
page is never written silently.

Reason to exist: Claude Artifacts allow scripts from a few CDNs but block
external stylesheets, so a page built on Pico and a highlighter theme
arrives there unstyled unless the CSS travels inside the file.
"""
import argparse
import re
import sys
import urllib.error
import urllib.request

LINK = re.compile(r"<link\b[^>]*>", re.IGNORECASE)
ATTR = re.compile(r"""([a-zA-Z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))""")


def attributes(tag):
    return {name.lower(): next(v for v in (dq, sq, bare) if v is not None)
            for name, dq, sq, bare in ATTR.findall(tag)}


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "inject-styles"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read().decode("utf-8")


def inject(html):
    def replace(match):
        tag = match.group(0)
        attrs = attributes(tag)
        href = attrs.get("href", "")
        if attrs.get("rel", "").lower() != "stylesheet" or "://" not in href:
            return tag
        css = fetch(href).replace("</style", "<\\/style")
        media = f' media="{attrs["media"]}"' if attrs.get("media") else ""
        return f"<style{media}>\n/* {href} */\n{css}\n</style>"

    return LINK.sub(replace, html)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("html", help="HTML file to read")
    parser.add_argument("-o", "--output", help="write here instead of stdout")
    args = parser.parse_args()

    with open(args.html, encoding="utf-8") as source:
        html = source.read()
    try:
        result = inject(html)
    except (urllib.error.URLError, OSError) as error:
        print(f"inject-styles: cannot fetch a stylesheet: {error}", file=sys.stderr)
        return 1
    if args.output:
        with open(args.output, "w", encoding="utf-8") as target:
            target.write(result)
    else:
        sys.stdout.write(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
