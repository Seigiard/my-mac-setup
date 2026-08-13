import { describe, expect, test } from "bun:test";

import type { FlowBlock, FlowSpec } from "./flow-spec.ts";
import { bindProofTargets, blockNodeId, canonicalSpecJson, needsWorkspace, specHash, topoOrder } from "./flow-run.ts";

function fb(over: Partial<FlowBlock> & { id: string; block: string }): FlowBlock {
  return { input: {}, retries: 0, timeoutMs: 1000, after: [], bindTo: [], waive: "none", ...over };
}

function makeSpec(blocks: FlowBlock[], over: Partial<FlowSpec> = {}): FlowSpec {
  return {
    task: { description: "t", classification: null },
    repo: "/tmp/r",
    setupCmdRef: null,
    budgetUsd: null,
    blocks,
    artifactsFrom: null,
    ...over,
  };
}

describe("blockNodeId", () => {
  test("namespaces spec ids under b:", () => {
    expect(blockNodeId("repro")).toBe("b:repro");
  });
});

describe("needsWorkspace", () => {
  test("true when any block needs a workspace", () => {
    const spec = makeSpec([fb({ id: "a", block: "doc-review" }), fb({ id: "b", block: "work" })]);
    expect(needsWorkspace(spec, (name) => name === "work")).toBe(true);
  });

  test("false for a workspace-free flow", () => {
    const spec = makeSpec([fb({ id: "a", block: "doc-review" })]);
    expect(needsWorkspace(spec, () => false)).toBe(false);
  });
});

describe("topoOrder", () => {
  test("orders by after edges, tie-breaking by id for determinism", () => {
    const spec = [
      fb({ id: "pr", block: "pr", after: ["review"] }),
      fb({ id: "review", block: "code-review", after: ["scan", "fix"] }),
      fb({ id: "fix", block: "work", after: ["scan"] }),
      fb({ id: "scan", block: "secret-scan" }),
    ];
    const order = topoOrder(spec).map((b) => b.id);
    expect(order[0]).toBe("scan");
    expect(order.indexOf("fix")).toBeLessThan(order.indexOf("review"));
    expect(order.indexOf("review")).toBeLessThan(order.indexOf("pr"));
    // deterministic across runs
    expect(topoOrder(spec).map((b) => b.id)).toEqual(order);
  });

  test("throws on a residual cycle", () => {
    const spec = [fb({ id: "a", block: "x", after: ["b"] }), fb({ id: "b", block: "x", after: ["a"] })];
    expect(() => topoOrder(spec)).toThrow(/cyclic/);
  });
});

describe("bindProofTargets", () => {
  test("maps bindTo edges to namespaced node ids", () => {
    expect(bindProofTargets(fb({ id: "review", block: "cr", bindTo: ["fix", "scan"] }))).toEqual(["b:fix", "b:scan"]);
  });
});

describe("specHash / canonicalSpecJson", () => {
  test("hash is invariant to key order", () => {
    const a = makeSpec([fb({ id: "x", block: "work" })]);
    const b = makeSpec([fb({ id: "x", block: "work" })], { repo: "/tmp/r" });
    expect(specHash(a)).toBe(specHash(b));
    expect(canonicalSpecJson(a)).toBe(canonicalSpecJson(b));
  });

  test("hash changes when a block changes", () => {
    const a = makeSpec([fb({ id: "x", block: "work" })]);
    const b = makeSpec([fb({ id: "x", block: "work", retries: 2 })]);
    expect(specHash(a)).not.toBe(specHash(b));
  });
});
