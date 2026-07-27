import { describe, expect, test } from "bun:test";

import { parseNumstat, shouldRunSimplify, simplifyCommitDecision, type DiffFileStat } from "./stage-gate.ts";

function file(path: string, linesChanged: number, binary = false): DiffFileStat {
  return { path, linesChanged, binary };
}

describe("parseNumstat", () => {
  test("parses added/deleted/path, sums executable lines", () => {
    // #given a numstat with one text file
    const files = parseNumstat("12\t3\tsrc/util.ts\n");
    // #then linesChanged is added+deleted
    expect(files).toHaveLength(1);
    expect(files[0]).toEqual({ path: "src/util.ts", linesChanged: 15, binary: false });
  });

  test("marks binary files (dash counts) and zeroes their lines", () => {
    const files = parseNumstat("-\t-\tassets/logo.png\n");
    expect(files[0].binary).toBe(true);
    expect(files[0].linesChanged).toBe(0);
  });

  test("skips blank / malformed lines without throwing", () => {
    const files = parseNumstat("\n5\t5\ta.ts\nnot-a-row\n");
    expect(files).toHaveLength(1);
    expect(files[0].path).toBe("a.ts");
  });
});

describe("shouldRunSimplify", () => {
  test("empty diff → skip, not inconclusive", () => {
    const r = shouldRunSimplify([]);
    expect(r.run).toBe(false);
    expect(r.inconclusive).toBe(false);
    expect(r.reason).toContain("empty");
  });

  test("markdown/lockfile-only diff → skip with the category named", () => {
    // #given only docs and a lockfile changed
    const r = shouldRunSimplify([file("README.md", 40), file("bun.lock", 200)]);
    // #then skip (no-yield), never inconclusive, reason names the categories
    expect(r.run).toBe(false);
    expect(r.inconclusive).toBe(false);
    expect(r.reason).toContain("docs");
    expect(r.reason).toContain("lockfile");
  });

  test("generated + vendored + binary only → skip", () => {
    const r = shouldRunSimplify([file("dist/bundle.js", 900), file("node_modules/x/index.js", 10), file("logo.png", 0, true)]);
    expect(r.run).toBe(false);
    expect(r.inconclusive).toBe(false);
  });

  test("substantial executable-code diff → run", () => {
    const r = shouldRunSimplify([file("src/service.ts", 60), file("README.md", 100)]);
    // #then run — 60 executable lines clears the threshold; docs don't count against it
    expect(r.run).toBe(true);
    expect(r.inconclusive).toBe(false);
  });

  test("small code diff → inconclusive (defers to classifier)", () => {
    const r = shouldRunSimplify([file("src/util.ts", 4)]);
    // #then neither clear-skip nor clear-run → inconclusive, skip-when-unsure default
    expect(r.run).toBe(false);
    expect(r.inconclusive).toBe(true);
    expect(r.reason).toContain("classifier");
  });
});

describe("simplifyCommitDecision", () => {
  test("ok + applied edits → commit and rescan", () => {
    expect(simplifyCommitDecision("ok", true)).toEqual({ commit: true, rescan: true });
  });

  test("ok but nothing applied → no commit, no rescan", () => {
    expect(simplifyCommitDecision("ok", false)).toEqual({ commit: false, rescan: false });
  });

  test("skipped → no commit, no rescan", () => {
    expect(simplifyCommitDecision("skipped", false)).toEqual({ commit: false, rescan: false });
  });

  test("degraded (apply reverted) → no commit, no rescan", () => {
    expect(simplifyCommitDecision("degraded", false)).toEqual({ commit: false, rescan: false });
  });
});
