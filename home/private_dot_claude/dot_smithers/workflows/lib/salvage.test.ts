import { describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { synthesizeSalvagedRecord, type SalvagedBlockRow } from "./salvage.ts";

function row(over: Partial<SalvagedBlockRow> & { blockId: string }): SalvagedBlockRow {
  return { status: "green", payloadJson: "{}", ...over };
}

describe("synthesizeSalvagedRecord", () => {
  test("carries every recorded block status into the record", () => {
    // #given a run killed after two blocks reported
    const rows = [row({ blockId: "repro", status: "green" }), row({ blockId: "fix", status: "failed" })];

    // #when the record is synthesized
    const { record } = synthesizeSalvagedRecord({ runId: "run-1", rows, worktreePath: null, specHash: "abc", archiveDir: "/arch" });

    // #then both statuses survive and the record is marked salvaged
    expect(record.record.blocks).toEqual([
      { blockId: "repro", block: "repro", status: "green" },
      { blockId: "fix", block: "fix", status: "failed" },
    ]);
    expect(record.salvaged).toBe(true);
  });

  test("an unrecognised status reads as non-terminal, never green", () => {
    // #given a row whose status is not one the reviewer knows
    const { record } = synthesizeSalvagedRecord({
      runId: "run-1",
      rows: [row({ blockId: "a", status: "who-knows" })],
      worktreePath: null,
      specHash: null,
      archiveDir: "/arch",
    });

    // #then a killed run's unreadable verdict is missing evidence, not a pass
    expect(record.record.blocks[0].status).toBe("non-terminal");
  });

  test("keeps the spec hash but never invents a spec", () => {
    // #given gate0 persisted only the hash
    const { record } = synthesizeSalvagedRecord({ runId: "run-1", rows: [row({ blockId: "a" })], worktreePath: null, specHash: "deadbeef", archiveDir: "/arch" });

    // #then the hash is kept so a mismatch stays detectable, and spec is null
    expect(record.specHash).toBe("deadbeef");
    expect(record.spec).toBeNull();
  });

  test("recovers manifest artifacts from a worktree that outlived the run", () => {
    // #given a killed run whose worktree still holds a manifest artifact
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "salvage-test-"));
    const worktree = path.join(dir, "worktree");
    fs.mkdirSync(worktree);
    const artifact = path.join(worktree, "report.json");
    fs.writeFileSync(artifact, "evidence");
    const rows = [row({ blockId: "proof", payloadJson: JSON.stringify({ manifest: [{ name: "report.json", path: artifact }] }) })];

    // #when the run is salvaged
    const { record } = synthesizeSalvagedRecord({ runId: "run-1", rows, worktreePath: worktree, specHash: null, archiveDir: path.join(dir, "archive") });

    // #then the artifact is copied into the archive with its content
    expect(record.artifacts).toHaveLength(1);
    expect(fs.readFileSync(record.artifacts[0].path, "utf8")).toBe("evidence");
  });

  test("a gone worktree yields statuses only, with the artifact recorded as skipped", () => {
    // #given a run whose worktree was already cleaned up
    const rows = [row({ blockId: "proof", payloadJson: JSON.stringify({ manifest: [{ name: "r.json", path: "/gone/r.json" }] }) })];

    const { record } = synthesizeSalvagedRecord({ runId: "run-1", rows, worktreePath: null, specHash: null, archiveDir: "/arch" });

    // #then nothing is copied and the loss is recorded rather than silent
    expect(record.artifacts).toEqual([]);
    expect(record.skippedArtifacts[0].reason).toContain("outside the run worktree");
  });
});
