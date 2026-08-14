import { describe, expect, test } from "bun:test";

import type { FlowBlock, FlowSpec } from "./flow-spec.ts";
import { blockNodeId, canonicalSpecJson, dispatchableBlocks, dispatchNodeId, formatFlowPlan, formatPrBody, needsWorkspace, specHash, topoOrder } from "./flow-run.ts";

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

describe("dispatchableBlocks", () => {
  // Regression: ctx.prove returns undefined for a row that does not exist yet.
  // Passing that undefined to a Task's bind parked the node as waiting-bound
  // and the whole run as waiting-event, silently and permanently.
  const chain = [
    fb({ id: "scan", block: "secret-scan" }),
    fb({ id: "fix", block: "work", after: ["scan"], bindTo: ["scan"] }),
    fb({ id: "pr", block: "pr", after: ["fix"], bindTo: ["fix"] }),
  ];

  test("withholds a block whose bindTo target has no row yet", () => {
    // #given no block has recorded a row
    // #when the render asks which blocks it may dispatch
    const dispatchable = dispatchableBlocks(chain, () => undefined);

    // #then only the unbound first block is rendered
    expect(dispatchable.map((d) => d.block.id)).toEqual(["scan"]);
  });

  test("maps bindTo edges to the node ids that hold the rows", () => {
    // #given the first block has recorded its row
    const dispatchable = dispatchableBlocks(chain, (id) => (id === "scan" ? "b:scan" : undefined));

    // #then the bound block joins the render carrying its resolved target
    expect(dispatchable.map((d) => d.block.id)).toEqual(["scan", "fix"]);
    expect(dispatchable[1].bindNodeIds).toEqual(["b:scan"]);
  });

  test("binds to the guard's crash node when that is where the row landed", () => {
    // #given the first block threw, so its verdict sits under the crash node
    const dispatchable = dispatchableBlocks(chain, (id) => (id === "scan" ? "b:scan-crashed" : undefined));

    // #then the dependent still dispatches, bound to the crash row
    expect(dispatchable[1].bindNodeIds).toEqual(["b:scan-crashed"]);
  });

  test("stops at the first unready block rather than skipping past it", () => {
    // #given the middle block has no row, but the last one somehow does
    const dispatchable = dispatchableBlocks(chain, (id) => (id === "scan" ? "b:scan" : undefined));

    // #then nothing past the unready block is rendered — after-order holds
    expect(dispatchable.map((d) => d.block.id)).not.toContain("pr");
  });

  test("renders every block once all rows exist", () => {
    const dispatchable = dispatchableBlocks(chain, (id) => `b:${id}`);
    expect(dispatchable.map((d) => d.block.id)).toEqual(["scan", "fix", "pr"]);
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

describe("dispatchNodeId", () => {
  test("derives a stable second node from the block node, outside spec id grammar", () => {
    // #given block ids are lowercase kebab and cannot contain a colon
    const nodeId = blockNodeId("do-the-thing");

    // #when / #then the dispatch node is derived, so resume still matches
    expect(dispatchNodeId(nodeId)).toBe("b:do-the-thing:dispatch");
    expect(dispatchNodeId(nodeId)).toBe(dispatchNodeId(nodeId));
  });
});

describe("formatFlowPlan (R10)", () => {
  const lookup = (name: string) =>
    ({
      work: { estUsd: 20, kind: "agent" },
      "secret-scan": { estUsd: 0, kind: "compute" },
    })[name];

  function planBlock(over: Partial<FlowBlock> = {}): FlowBlock {
    return { id: "b1", block: "work", input: {}, retries: 0, timeoutMs: 1000, after: [], bindTo: [], waive: "none", ...over };
  }

  test("lists blocks in execution order, not spec order", () => {
    // #given a spec whose declared order is the reverse of its dependency order
    const blocks = [
      planBlock({ id: "second", block: "secret-scan", after: ["first"] }),
      planBlock({ id: "first", block: "work", after: [] }),
    ];

    // #when
    const out = formatFlowPlan("a task", blocks, lookup);

    // #then
    expect(out.indexOf("first")).toBeLessThan(out.indexOf("second"));
  });

  test("sums the per-block cost profiles into one estimate", () => {
    // #given two paid blocks
    const blocks = [planBlock({ id: "a" }), planBlock({ id: "b", after: ["a"] })];

    // #when / #then
    expect(formatFlowPlan("a task", blocks, lookup)).toContain("estimated ~$40");
  });

  test("reports a retry ceiling separately from the baseline", () => {
    // #given a block allowed two extra attempts
    const blocks = [planBlock({ id: "a", retries: 2 })];

    // #when / #then one attempt costs 20, three cost 60
    const out = formatFlowPlan("a task", blocks, lookup);
    expect(out).toContain("estimated ~$20");
    expect(out).toContain("up to ~$60");
  });

  test("omits the ceiling when no block can retry", () => {
    // #given
    const blocks = [planBlock({ id: "a", retries: 0 })];

    // #when / #then a ceiling equal to the baseline is noise, not information
    expect(formatFlowPlan("a task", blocks, lookup)).not.toContain("up to ~$");
  });

  test("marks a block the registry does not know instead of dropping it", () => {
    // #given a spec naming a block outside the catalog
    const blocks = [planBlock({ id: "mystery", block: "not-a-block" })];

    // #when / #then the reader has to see it
    const out = formatFlowPlan("a task", blocks, lookup);
    expect(out).toContain("mystery");
    expect(out).toContain("UNKNOWN BLOCK");
  });
});

describe("formatPrBody", () => {
  const blocks = [
    { blockId: "fix", block: "work", status: "green" },
    { blockId: "scan", block: "secret-scan", status: "failed" },
  ];

  test("embeds the spec and every recorded block status (R11)", () => {
    const body = formatPrBody("run-1", '{"task":{"description":"d"}}', blocks);
    expect(body).toContain('{"task":{"description":"d"}}');
    expect(body).toContain("| `fix` | work | green |");
    expect(body).toContain("| `scan` | secret-scan | failed |");
  });

  test("says the outcome record comes later rather than implying it is embedded", () => {
    // #given the epilog has not run when the pr block opens the PR
    expect(formatPrBody("run-1", "{}", blocks)).toContain("written by the epilog, after this PR opens");
  });

  test("a PR opened before any block recorded says so instead of showing an empty table", () => {
    expect(formatPrBody("run-1", "{}", [])).toContain("no block had recorded a status");
  });
});
