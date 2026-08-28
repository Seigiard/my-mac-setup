#!/usr/bin/env python3
"""Per-scenario verifier for the bats -> bashunit migration experiment.

Compares one Bats TAP run against one bashunit run (JSON report + TAP stdout)
scenario by scenario, keyed by the manifest. Aggregate counts are never used
as evidence: every manifest scenario must appear exactly once on each side.

Checks per scenario:
  - present on both sides exactly once (missing/duplicated detection)
  - status parity (pass/fail/skip)
  - skip reason parity (exact string)
Extra tests on either side (not in the manifest) are errors.

Usage:
  verify_bats_bashunit.py --manifest tests/bashunit/manifest.tsv \
      --bats-file <name>.bats --bats-tap bats.tap \
      --bashunit-json report.json --bashunit-tap bashunit.tap

Exit 0 = full parity; 1 = any mismatch (each printed as MISMATCH/MISSING/DUP).
"""

import argparse
import json
import re
import sys

BATS_LINE = re.compile(r"^(ok|not ok) (\d+) (.*?)(?: # skip(?: (.*))?)?$")
BU_TAP_LINE = re.compile(
    r"^(ok|not ok) (\d+) - (.*?)(?: # (SKIP|RISKY|TODO)(?: (.*))?)?$"
)


def parse_bats_tap(path):
    """name -> (status, skip_reason). status in pass/fail/skip."""
    out = {}
    dups = []
    for line in open(path):
        m = BATS_LINE.match(line.rstrip("\n"))
        if not m:
            continue
        okness, _num, name, skip_reason = m.groups()
        if " # skip" in line:
            status = "skip"
        else:
            status = "pass" if okness == "ok" else "fail"
        if name in out:
            dups.append(name)
        out[name] = (status, skip_reason or "")
    return out, dups


def parse_bashunit(json_path, tap_path):
    """name -> (status, skip_reason)."""
    data = json.load(open(json_path))
    # "risky" = passed with zero recorded assertions. Bats has no such notion:
    # a test whose checks are bare commands + fail() is an ordinary pass there,
    # so risky maps to pass for parity purposes (bashunit exits 0 for it too).
    status_map = {"passed": "pass", "failed": "fail", "skipped": "skip",
                  "risky": "pass"}
    out = {}
    dups = []
    for t in data["tests"]:
        name = t["name"]
        status = status_map.get(t["status"], t["status"])
        if name in out:
            dups.append(name)
        out[name] = (status, "")
    # Skip reasons only exist in TAP stdout.
    reasons = {}
    if tap_path:
        for line in open(tap_path):
            m = BU_TAP_LINE.match(line.rstrip("\n"))
            if m and m.group(4) == "SKIP":
                reasons[m.group(3)] = m.group(5) or ""
    for name, (status, _)  in list(out.items()):
        if status == "skip":
            out[name] = (status, reasons.get(name, ""))
    return out, dups


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--bats-file", required=True,
                    help="basename, e.g. platform.bats — selects manifest rows")
    ap.add_argument("--bats-tap", required=True)
    ap.add_argument("--bashunit-json", required=True)
    ap.add_argument("--bashunit-tap")
    args = ap.parse_args()

    expected = []  # names in manifest order
    for line in open(args.manifest):
        cols = line.rstrip("\n").split("\t")
        if cols[0] == args.bats_file:
            expected.append(cols[2])
    if not expected:
        print(f"ERROR: no manifest rows for {args.bats_file}")
        sys.exit(1)
    if len(set(expected)) != len(expected):
        print("DUP: duplicated scenario in manifest")
        sys.exit(1)

    bats, bats_dups = parse_bats_tap(args.bats_tap)
    bu, bu_dups = parse_bashunit(args.bashunit_json, args.bashunit_tap)

    problems = 0

    def report(kind, name, detail=""):
        nonlocal problems
        problems += 1
        print(f"{kind}: {name}" + (f" — {detail}" if detail else ""))

    for name in bats_dups:
        report("DUP-BATS", name)
    for name in bu_dups:
        report("DUP-BASHUNIT", name)

    for name in expected:
        b = bats.get(name)
        u = bu.get(name)
        if b is None:
            report("MISSING-IN-BATS", name)
        if u is None:
            report("MISSING-IN-BASHUNIT", name)
        if b is None or u is None:
            continue
        if b[0] != u[0]:
            report("MISMATCH-STATUS", name, f"bats={b[0]} bashunit={u[0]}")
        elif b[0] == "skip" and b[1] != u[1]:
            report("MISMATCH-SKIP-REASON", name,
                   f"bats={b[1]!r} bashunit={u[1]!r}")

    for name in bats:
        if name not in set(expected):
            report("EXTRA-IN-BATS", name)
    for name in bu:
        if name not in set(expected):
            report("EXTRA-IN-BASHUNIT", name)

    total = len(expected)
    if problems:
        print(f"RESULT: FAIL — {problems} problem(s) across {total} scenarios")
        sys.exit(1)
    print(f"RESULT: OK — {total}/{total} scenarios in parity")


if __name__ == "__main__":
    main()
