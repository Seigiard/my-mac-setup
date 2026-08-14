import { describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { ARTIFACT_SUBDIR, INBOUND_SUBDIR, copyArtifacts, inboundPromptNote, parseArchiveManifest, planArtifactArchive, planInboundDelivery } from "./archive.ts";

const allowAll = () => true;

function payload(blockId: string, manifest: unknown): { blockId: string; payloadJson: string } {
  return { blockId, payloadJson: JSON.stringify({ manifest }) };
}

describe("planArtifactArchive", () => {
  test("plans a copy for every manifest entry", () => {
    // #given one block naming two artifacts
    const payloads = [payload("proof", [{ name: "a.txt", path: "/w/a.txt" }, { name: "b.txt", path: "/w/b.txt" }])];

    // #when the archive is planned
    const plan = planArtifactArchive(payloads, "/arch", allowAll);

    // #then both are destined for the artifacts subdirectory, namespaced by block
    expect(plan.entries.map((e) => e.destination)).toEqual([
      path.join("/arch", ARTIFACT_SUBDIR, "proof-a.txt"),
      path.join("/arch", ARTIFACT_SUBDIR, "proof-b.txt"),
    ]);
  });

  test("ignores a block payload that carries no manifest", () => {
    // #given a compute block whose payload is a scan result, not a manifest
    const payloads = [{ blockId: "scan", payloadJson: JSON.stringify({ state: "clean", details: "" }) }];

    // #then it contributes nothing and is not reported as skipped
    const plan = planArtifactArchive(payloads, "/arch", allowAll);
    expect(plan.entries).toEqual([]);
    expect(plan.skipped).toEqual([]);
  });

  test("refuses an artifact path outside the run worktree", () => {
    // #given a manifest naming a file outside the worktree
    const payloads = [payload("proof", [{ name: "secrets", path: "/etc/passwd" }])];

    // #when containment rejects it
    const plan = planArtifactArchive(payloads, "/arch", (candidate) => candidate.startsWith("/w/"));

    // #then it is skipped with the reason recorded, never copied
    expect(plan.entries).toEqual([]);
    expect(plan.skipped[0].reason).toContain("outside the run worktree");
  });

  test("two blocks naming the same file do not collide", () => {
    const payloads = [
      payload("first", [{ name: "report.json", path: "/w/1.json" }]),
      payload("second", [{ name: "report.json", path: "/w/2.json" }]),
    ];
    const destinations = planArtifactArchive(payloads, "/arch", allowAll).entries.map((e) => path.basename(e.destination));
    expect(destinations).toEqual(["first-report.json", "second-report.json"]);
  });

  test("a repeated name within one block gets a suffix instead of overwriting", () => {
    const payloads = [payload("proof", [{ name: "out/log", path: "/w/a" }, { name: "out-log", path: "/w/b" }])];
    const destinations = planArtifactArchive(payloads, "/arch", allowAll).entries.map((e) => path.basename(e.destination));
    expect(destinations).toEqual(["proof-out-log", "proof-out-log-2"]);
  });

  test("a manifest name with separators is flattened, never escaping the archive", () => {
    const payloads = [payload("proof", [{ name: "../../etc/passwd", path: "/w/x" }])];
    const entry = planArtifactArchive(payloads, "/arch", allowAll).entries[0];
    expect(path.dirname(entry.destination)).toBe(path.join("/arch", ARTIFACT_SUBDIR));
  });

  test("an unparseable payload is skipped with a reason, not thrown", () => {
    const plan = planArtifactArchive([{ blockId: "proof", payloadJson: "{not json" }], "/arch", allowAll);
    expect(plan.skipped[0].reason).toContain("does not parse");
  });
});

describe("copyArtifacts", () => {
  test("copies planned files and reports what landed", () => {
    // #given a real source file and an archive directory
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "archive-test-"));
    const source = path.join(dir, "source.txt");
    fs.writeFileSync(source, "evidence");
    const archiveDir = path.join(dir, "archive");

    // #when the plan is executed
    const plan = planArtifactArchive([payload("proof", [{ name: "source.txt", path: source }])], archiveDir, allowAll);
    const result = copyArtifacts(plan);

    // #then the file exists in the archive with its content intact
    expect(result.copied).toHaveLength(1);
    expect(fs.readFileSync(result.copied[0].destination, "utf8")).toBe("evidence");
  });

  test("a missing source is recorded as skipped rather than failing the epilog", () => {
    // #given a manifest pointing at a file that no longer exists
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "archive-test-"));
    const plan = planArtifactArchive([payload("proof", [{ name: "gone.txt", path: path.join(dir, "gone.txt") }])], path.join(dir, "archive"), allowAll);

    // #when the copy runs
    const result = copyArtifacts(plan);

    // #then nothing is copied, nothing throws, and the reason is kept
    expect(result.copied).toEqual([]);
    expect(result.skipped[0].reason).toContain("copy failed");
  });
});

describe("parseArchiveManifest", () => {
  test("reads the artifacts a prior run published", () => {
    const record = JSON.stringify({ artifacts: [{ blockId: "proof", name: "a.txt", path: "/arch/proof-a.txt" }] });
    expect(parseArchiveManifest(record)).toEqual([{ blockId: "proof", name: "a.txt", path: "/arch/proof-a.txt" }]);
  });

  test("a record with no artifacts hands over nothing rather than throwing", () => {
    expect(parseArchiveManifest(JSON.stringify({ record: {} }))).toEqual([]);
    expect(parseArchiveManifest("{not json")).toEqual([]);
  });

  test("drops malformed entries instead of delivering an undefined path", () => {
    const record = JSON.stringify({ artifacts: [{ name: "a" }, { blockId: "p", name: "b", path: "/x" }] });
    expect(parseArchiveManifest(record)).toHaveLength(1);
  });
});

describe("planInboundDelivery", () => {
  test("addresses a prior run's artifacts into the new worktree", () => {
    // #given an artifact that exists in the prior run's archive
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "inbound-test-"));
    const source = path.join(dir, "proof-report.json");
    fs.writeFileSync(source, "prior evidence");

    // #when delivery into a new worktree is planned and run
    const plan = planInboundDelivery([{ blockId: "proof", name: "report.json", path: source }], path.join(dir, "worktree"));
    const result = copyArtifacts(plan);

    // #then the file lands under the inbound subdirectory, content intact
    expect(path.basename(path.dirname(result.copied[0].destination))).toBe(INBOUND_SUBDIR);
    expect(fs.readFileSync(result.copied[0].destination, "utf8")).toBe("prior evidence");
  });

  test("an artifact the prior record names but no longer exists is skipped, not silently dropped", () => {
    const plan = planInboundDelivery([{ blockId: "proof", name: "gone", path: "/nope/gone" }], "/worktree");
    expect(plan.entries).toEqual([]);
    expect(plan.skipped[0].reason).toContain("no longer exists");
  });
});

describe("inboundPromptNote", () => {
  test("names every delivered artifact and marks the contents untrusted", () => {
    // #given one artifact was handed over
    const note = inboundPromptNote([{ blockId: "proof", name: "report.json", source: "/a", destination: "/w/.se-flow-inbound/proof-report.json" }]);

    // #then the leg is told where it is and not to follow it
    expect(note).toContain("/w/.se-flow-inbound/proof-report.json");
    expect(note).toContain("untrusted data");
  });

  test("no handoff means no note, so an ordinary prompt is unchanged", () => {
    expect(inboundPromptNote([])).toBe("");
  });
});
