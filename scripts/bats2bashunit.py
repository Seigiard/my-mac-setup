#!/usr/bin/env python3
"""Deterministically convert a Bats file to a bashunit test file.

The @test bodies are emitted verbatim; all Bats vocabulary is supplied at
runtime by tests/bashunit/bats-compat.bash. The converter also emits a
manifest row per scenario so the side-by-side verifier can prove a
one-to-one mapping (missing or duplicated scenarios fail the conversion).

Usage:
  bats2bashunit.py [--serial] --out-dir tests/bashunit --manifest tests/bashunit/manifest.tsv tests/<file>.bats ...

Layout of a generated file (tests/bashunit/<base>_test.sh):
  header -> source compat -> _bats_file_init -> passthrough top-level code
  (load/setup/teardown/helpers, verbatim) -> hook wrappers -> one function
  per @test with _bats_test_init as its first statement.
"""

import argparse
import re
import sys
from pathlib import Path

TEST_RE = re.compile(r'^@test "(.*)" \{$')


def shell_squote(s: str) -> str:
    return "'" + s.replace("'", "'\\''") + "'"


def slugify(name: str, index: int) -> str:
    slug = re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")[:48].rstrip("_")
    return f"test_{index:03d}_{slug}"


def convert(src: Path, out_dir: Path, serial: bool):
    lines = src.read_text().splitlines()
    base = src.stem  # e.g. "platform" from tests/platform.bats
    out_path = out_dir / f"{base}_test.sh"

    # Transform ONLY the @test lines, in place; every other byte stays
    # verbatim so heredocs, nested braces, and quoting survive untouched —
    # bash itself owns the closing braces, exactly as under Bats.
    body_lines: list[str] = []
    tests: list[tuple[int, str]] = []  # (index, name)
    names_seen = {}
    has_setup_file = False
    has_teardown_file = False
    has_teardown = False

    if lines and lines[0].startswith("#!"):
        lines = lines[1:]  # only the file's own shebang — heredocs keep theirs

    index = 0
    for line in lines:
        m = TEST_RE.match(line)
        if m:
            index += 1
            name = m.group(1)
            if name in names_seen:
                sys.exit(f"{src}: duplicate @test name: {name!r}")
            names_seen[name] = index
            fn = slugify(name, index)
            body_lines.append(f"function {fn}() {{")
            body_lines.append(f"  _bats_test_init {index} {shell_squote(name)}")
            tests.append((index, name))
            continue
        if re.match(r"^(function )?setup_file\s*\(\)", line):
            has_setup_file = True
        if re.match(r"^(function )?teardown_file\s*\(\)", line):
            has_teardown_file = True
        if re.match(r"^(function )?teardown\s*\(\)", line):
            has_teardown = True
        body_lines.append(line)

    if not tests:
        sys.exit(f"{src}: no @test blocks found")

    out = []
    out.append("#!/usr/bin/env bash")
    if serial:
        out.append("# bashunit: no-parallel-tests")
    out.append(f"# Generated from {src} by scripts/bats2bashunit.py — DO NOT EDIT.")
    out.append('source "$(dirname "${BASH_SOURCE[0]}")/bats-compat.bash"')
    out.append(
        f'_bats_file_init "$(dirname "${{BASH_SOURCE[0]}}")/../{src.name}"'
    )
    out.append("")
    out.extend(body_lines)
    out.append("")
    out.append("function set_up_before_script() {")
    if has_setup_file:
        out.append("  setup_file")
    out.append("  :")
    out.append("}")
    out.append("")
    out.append("function tear_down_after_script() {")
    if has_teardown_file:
        out.append("  teardown_file")
    out.append("  _bats_file_cleanup")
    out.append("}")
    if has_teardown:
        out.append("")
        out.append("function tear_down() { _bats_run_teardown; }")
    out.append("")

    manifest_rows = []
    for index, name in tests:
        fn = slugify(name, index)
        manifest_rows.append((src.name, str(index), name, fn, out_path.name))

    out_path.write_text("\n".join(out) + "\n")
    return out_path, manifest_rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--serial", action="store_true",
                    help="emit '# bashunit: no-parallel-tests'")
    ap.add_argument("--out-dir", required=True, type=Path)
    ap.add_argument("--manifest", required=True, type=Path)
    ap.add_argument("--append-manifest", action="store_true")
    ap.add_argument("sources", nargs="+", type=Path)
    args = ap.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    rows = []
    for src in args.sources:
        out_path, manifest_rows = convert(src, args.out_dir, args.serial)
        rows.extend(manifest_rows)
        print(f"{src} -> {out_path} ({len(manifest_rows)} tests)")

    mode = "a" if args.append_manifest else "w"
    with args.manifest.open(mode) as fh:
        for row in rows:
            fh.write("\t".join(row) + "\n")

    # Reject duplicated function names across the manifest (one-to-one mapping).
    seen = set()
    for line in args.manifest.read_text().splitlines():
        key = (line.split("\t")[4], line.split("\t")[3])
        if key in seen:
            sys.exit(f"duplicate mapping in manifest: {key}")
        seen.add(key)


if __name__ == "__main__":
    main()
