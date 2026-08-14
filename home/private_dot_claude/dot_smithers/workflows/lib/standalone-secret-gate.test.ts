import { describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as path from "node:path";

// Wiring checks over harness SOURCE, in the idiom of pipeline-simplify.test.ts.
// The gate's behavior is covered by pre-external-gate.test.ts; what no unit test
// can see is whether each harness calls it, and calls it BEFORE it creates the
// snapshot the external legs read. Order is the whole property: a gate that runs
// after `worktree add` leaves a readable copy in /tmp even when it refuses.
const WORKFLOWS_DIR = path.join(import.meta.dir, "..");

function source(file: string): string {
  return fs.readFileSync(path.join(WORKFLOWS_DIR, file), "utf8");
}

function indexOf(src: string, needle: string): number {
  const i = src.indexOf(needle);
  if (i < 0) throw new Error(`not found in source: ${needle}`);
  return i;
}

describe("standalone pre-external secret gate wiring", () => {
  test("se-code-review гейтит снимок до создания worktree", () => {
    // #given the standalone code-review harness
    const src = source("se-code-review.tsx");

    // #when the gate call and the snapshot creation are located
    const gate = indexOf(src, "enforcePreExternalGate(");
    const worktree = indexOf(src, `"worktree", "add"`);

    // #then nothing is staged before the scan clears the snapshot
    expect(gate).toBeLessThan(worktree);
  });

  test("se-simplify гейтит снимок до создания worktree", () => {
    // #given the shared simplify harness
    const src = source("se-simplify.tsx");

    // #when the gate call and the snapshot creation are located
    const gate = indexOf(src, "enforcePreExternalGate(");
    const worktree = indexOf(src, `"worktree", "add"`);

    // #then the report legs never see an unscanned snapshot
    expect(gate).toBeLessThan(worktree);
  });

  test("se-simplify пропускает гейт только при preScanned от вызывающего", () => {
    // #given the simplify harness, which the pipeline calls after its own scan
    const src = source("se-simplify.tsx");

    // #when the guard around the gate is read
    // #then the only way past it is the caller's explicit preScanned claim
    expect(src).toContain("if (!preScanned) {");
  });

  test("se-doc-review гейтит документ до копирования в /tmp", () => {
    // #given the doc-review harness, whose payload is the document itself
    const src = source("se-doc-review.tsx");

    // #when the gate call and the copy are located
    const gate = indexOf(src, "enforcePreExternalGate(");
    const copy = indexOf(src, "fs.copyFileSync(docPath");

    // #then a refused document is never copied where opencode can read it
    expect(gate).toBeLessThan(copy);
  });

  test("se-pipeline объявляет свой скан субфлоу simplify (preScanned: true)", () => {
    // #given the pipeline, which already scans this range and can waive it
    const src = source("se-pipeline.tsx");

    // #when the simplify Subflow input is read
    const simplifyBlock = src.slice(indexOf(src, 'id="simplify"'), indexOf(src, 'id="simplify"') + 400);

    // #then the subflow does not re-refuse a range the operator already waived
    expect(simplifyBlock).toContain("preScanned: true");
  });
});
