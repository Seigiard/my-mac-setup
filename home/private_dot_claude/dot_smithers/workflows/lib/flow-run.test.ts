import { describe, expect, test } from "bun:test";

import type { FlowBlock, FlowSpec } from "./flow-spec.ts";
import {
  blockNodeId,
  canonicalSpecJson,
  dispatchableBlocks,
  dispatchNodeId,
  epilogShouldRender,
  flowVerdict,
  formatFlowPlan,
  formatPrBody,
  isRedStatus,
  needsWorkspace,
  specHash,
  topoOrder,
  withheldByBlock,
  type GateApprovalDecision,
  type RecordedBlock,
} from "./flow-run.ts";

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

// The row reader dispatchableBlocks takes. `green(...)` and `red(...)` build the
// settled rows a run persists; a block absent from the map has no row at all.
function rows(map: Record<string, RecordedBlock>): (id: string) => RecordedBlock | undefined {
  return (id) => map[id];
}

function green(nodeId: string): RecordedBlock {
  return { nodeId, status: "green" };
}

function red(nodeId: string, status = "failed"): RecordedBlock {
  return { nodeId, status };
}

function decisions(map: Record<string, GateApprovalDecision>): (id: string) => GateApprovalDecision {
  return (id) => map[id] ?? "pending";
}

describe("isRedStatus", () => {
  test("green is the only status that is not red", () => {
    // #given every status the blockOutput schema can carry
    // #when / #then anything that is not green is failure evidence
    expect(isRedStatus("green")).toBe(false);
    expect(["failed", "degraded", "stopped", "non-terminal"].every(isRedStatus)).toBe(true);
  });
});

describe("dispatchableBlocks — bindTo readiness", () => {
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
    const { dispatchable } = dispatchableBlocks(chain, rows({}));

    // #then only the unbound first block is rendered
    expect(dispatchable.map((d) => d.block.id)).toEqual(["scan"]);
  });

  test("maps bindTo edges to the node ids that hold the rows", () => {
    // #given the first block has recorded its row
    const { dispatchable } = dispatchableBlocks(chain, rows({ scan: green("b:scan") }));

    // #then the bound block joins the render carrying its resolved target
    expect(dispatchable.map((d) => d.block.id)).toEqual(["scan", "fix"]);
    expect(dispatchable[1]!.bindNodeIds).toEqual(["b:scan"]);
  });

  test("binds to the guard's crash node when that is where the row landed", () => {
    // #given the first block threw, so its verdict sits under the crash node —
    // and a crash is red, so the dependent binds to it only under waive approval
    const crashed = [
      fb({ id: "scan", block: "secret-scan", waive: "approval" }),
      fb({ id: "fix", block: "work", after: ["scan"], bindTo: ["scan"] }),
    ];

    // #when the operator waived the crashed gate
    const { dispatchable } = dispatchableBlocks(
      crashed,
      rows({ scan: red("b:scan-crashed", "non-terminal") }),
      decisions({ scan: "approved" }),
    );

    // #then the dependent still dispatches, bound to the crash row
    expect(dispatchable[1]!.bindNodeIds).toEqual(["b:scan-crashed"]);
  });

  test("stops at the first unready block rather than skipping past it", () => {
    // #given the middle block has no row, but the last one somehow does
    const { dispatchable } = dispatchableBlocks(chain, rows({ scan: green("b:scan"), pr: green("b:pr") }));

    // #then nothing past the unready block is rendered — after-order holds
    expect(dispatchable.map((d) => d.block.id)).not.toContain("pr");
  });

  test("renders every block once all rows exist and are green", () => {
    // #given every block settled green
    // #when / #then the whole flow is dispatchable
    const { dispatchable } = dispatchableBlocks(chain, rows({ scan: green("b:scan"), fix: green("b:fix"), pr: green("b:pr") }));
    expect(dispatchable.map((d) => d.block.id)).toEqual(["scan", "fix", "pr"]);
  });
});

// docs/issues/2026-08-15-003: a red block wrote a row, row PRESENCE was all this
// function read, and every successor dispatched — including `pr`, which opened a
// real pull request on a real remote after the gate said no.
describe("dispatchableBlocks — a red block withholds its successors", () => {
  const chain = [
    fb({ id: "scan", block: "secret-scan" }),
    fb({ id: "fix", block: "work", after: ["scan"] }),
    fb({ id: "commit", block: "commit-work", after: ["fix"] }),
    fb({ id: "open-pr", block: "pr", after: ["commit"] }),
  ];

  test("a red block's direct successor is withheld", () => {
    // #given the middle block settled red
    // #when
    const { dispatchable, withheld } = dispatchableBlocks(chain, rows({ scan: green("b:scan"), fix: red("b:fix") }));

    // #then the block that depends on it never reaches the render
    expect(dispatchable.map((d) => d.block.id)).toEqual(["scan", "fix"]);
    expect(withheld).toContain("commit");
  });

  test("withholding is transitive — a successor's successor is withheld too", () => {
    // #given the same red block, and a chain of two blocks behind it
    // #when
    const { dispatchable, withheld } = dispatchableBlocks(chain, rows({ scan: green("b:scan"), fix: red("b:fix") }));

    // #then the pr block, which depends on the withheld commit block, is
    // withheld as well — the one that publishes irreversibly
    expect(dispatchable.map((d) => d.block.id)).not.toContain("open-pr");
    expect(withheld).toEqual(["commit", "open-pr"]);
  });

  test("a bindTo edge withholds even without an after edge naming the red block", () => {
    // #given a block bound to a red producer through bindTo only
    const bound = [
      fb({ id: "scan", block: "secret-scan" }),
      fb({ id: "fix", block: "work", after: ["scan"], bindTo: ["scan"] }),
    ];

    // #when the producer settled red
    const { dispatchable } = dispatchableBlocks(bound, rows({ scan: red("b:scan") }));

    // #then the consumer is withheld, even though its bind target has a row
    expect(dispatchable.map((d) => d.block.id)).toEqual(["scan"]);
  });

  test("an independent branch still dispatches", () => {
    // #given a red block and a branch that does not depend on it
    const forked = [
      fb({ id: "repro", block: "work" }),
      fb({ id: "fix", block: "work", after: ["repro"] }),
      fb({ id: "notes", block: "research", after: ["repro"] }),
    ];

    // #when the fix branch goes red
    const { dispatchable, withheld } = dispatchableBlocks(forked, rows({ repro: green("b:repro"), fix: red("b:fix") }));

    // #then a red block stops what depends on it, not the whole DAG
    expect(dispatchable.map((d) => d.block.id)).toEqual(["repro", "fix", "notes"]);
    expect(withheld).toEqual([]);
  });

  test("a crashed block counts as red", () => {
    // #given a block whose every attempt threw, so the guard recorded its
    // verdict under the -crashed node as non-terminal
    // #when
    const { dispatchable } = dispatchableBlocks(chain, rows({ scan: green("b:scan"), fix: red("b:fix-crashed", "non-terminal") }));

    // #then a leg that died is not a leg that passed
    expect(dispatchable.map((d) => d.block.id)).toEqual(["scan", "fix"]);
  });

  test("a block that went red on an early attempt but green after a retry does not withhold", () => {
    // #given a block allowed retries whose SETTLED row is green — a thrown
    // attempt persists no row, and a red gate returns rather than throwing, so
    // the row a retry left behind is the only one there is
    const retried = [
      fb({ id: "scan", block: "secret-scan", retries: 2 }),
      fb({ id: "fix", block: "work", after: ["scan"] }),
    ];

    // #when
    const { dispatchable, stops } = dispatchableBlocks(retried, rows({ scan: green("b:scan"), fix: green("b:fix") }));

    // #then nothing is withheld — "red after retries" is what the settled row says
    expect(dispatchable.map((d) => d.block.id)).toEqual(["scan", "fix"]);
    expect(stops).toEqual([]);
  });

  test("names the red block that stopped the run", () => {
    // #given a red block under the default waive policy
    // #when
    const { stops } = dispatchableBlocks(chain, rows({ scan: green("b:scan"), fix: red("b:fix") }));

    // #then the stop names the block, its kind and its status
    expect(stops).toEqual([{ blockId: "fix", block: "work", status: "failed", reason: "stopped" }]);
  });

  test("run-1786777192782's spec no longer publishes a PR after the fix block gates red", () => {
    // #given the exact shape of the incident: `fix` red under waive "none",
    // with the five blocks that followed it on the live run
    const incident = [
      fb({ id: "fix", block: "work" }),
      fb({ id: "commit", block: "commit-work", after: ["fix"] }),
      fb({ id: "validate", block: "run-validate", after: ["commit"] }),
      fb({ id: "artifacts", block: "proof-artifacts", after: ["validate"] }),
      fb({ id: "scan", block: "secret-scan", after: ["artifacts"] }),
      fb({ id: "open-pr", block: "pr", after: ["scan"] }),
    ];

    // #when
    const { dispatchable, withheld } = dispatchableBlocks(incident, rows({ fix: red("b:fix") }));

    // #then only the red block ran; the irreversible one never reaches a remote
    expect(dispatchable.map((d) => d.block.id)).toEqual(["fix"]);
    expect(withheld).toEqual(["commit", "validate", "artifacts", "scan", "open-pr"]);
  });

  test("a red secret-scan withholds the publishing block that follows it", () => {
    // #given a scan that refused, then a pr block. A compute block may only
    // declare waive "none" (block-registry KIND_WAIVE_POLICIES), so no spec can
    // ask to waive this one — the hard stop is structural, not a policy choice.
    const scanned = [
      fb({ id: "scan", block: "secret-scan" }),
      fb({ id: "open-pr", block: "pr", after: ["scan"] }),
    ];

    // #when
    const { dispatchable } = dispatchableBlocks(scanned, rows({ scan: red("b:scan") }));

    // #then nothing publishes content the scan refused (KTD13)
    expect(dispatchable.map((d) => d.block.id)).toEqual(["scan"]);
  });

  test("a green run reports no stop and withholds nothing", () => {
    // #given every block settled green
    // #when
    const dispatch = dispatchableBlocks(chain, rows({ scan: green("b:scan"), fix: green("b:fix"), commit: green("b:commit"), "open-pr": green("b:open-pr") }));

    // #then
    expect(dispatch.stops).toEqual([]);
    expect(dispatch.withheld).toEqual([]);
  });
});

describe("dispatchableBlocks — waive: \"approval\"", () => {
  const chain = [
    fb({ id: "review", block: "code-review", waive: "approval" }),
    fb({ id: "commit", block: "commit-work", after: ["review"] }),
  ];
  const recorded = rows({ review: red("b:review") });

  test("withholds while the approval row is absent", () => {
    // #given a red block whose gate approval has not been decided
    // #when
    const { dispatchable, gateApprovals, stops } = dispatchableBlocks(chain, recorded, decisions({}));

    // #then the successor waits and the approval node is asked for
    expect(dispatchable.map((d) => d.block.id)).toEqual(["review"]);
    expect(gateApprovals).toEqual(["review"]);
    expect(stops[0]!.reason).toBe("parked");
  });

  test("withholds when the operator denied the waive", () => {
    // #given a denial recorded on the gate approval
    // #when
    const { dispatchable, stops } = dispatchableBlocks(chain, recorded, decisions({ review: "denied" }));

    // #then the successor stays withheld and the stop says why
    expect(dispatchable.map((d) => d.block.id)).toEqual(["review"]);
    expect(stops[0]!.reason).toBe("denied");
  });

  test("does not withhold once the approval records an approve", () => {
    // #given the operator waived the red gate
    // #when
    const { dispatchable, stops, gateApprovals } = dispatchableBlocks(chain, recorded, decisions({ review: "approved" }));

    // #then the successor proceeds, and the approval node stays in the graph so
    // the decision keeps a durable home
    expect(dispatchable.map((d) => d.block.id)).toEqual(["review", "commit"]);
    expect(stops).toEqual([]);
    expect(gateApprovals).toEqual(["review"]);
  });

  test("a green block with waive approval asks for no approval node", () => {
    // #given the block passed
    // #when
    const { gateApprovals } = dispatchableBlocks(chain, rows({ review: green("b:review"), commit: green("b:commit") }), decisions({}));

    // #then nothing to waive, so nothing to ask
    expect(gateApprovals).toEqual([]);
  });

  test("defaults to withholding when no approval reader is supplied", () => {
    // #given a caller that passes no decision reader at all
    // #when
    const { dispatchable } = dispatchableBlocks(chain, recorded);

    // #then the safe default is pending: an unreadable decision never releases
    // a red block
    expect(dispatchable.map((d) => d.block.id)).toEqual(["review"]);
  });

  test("the prompt for one gate lists only what that gate is holding", () => {
    // #given two red blocks, each with its own withheld successor
    const two = [
      fb({ id: "review", block: "code-review", waive: "approval" }),
      fb({ id: "scan", block: "secret-scan" }),
      fb({ id: "commit", block: "commit-work", after: ["review"] }),
      fb({ id: "open-pr", block: "pr", after: ["scan"] }),
    ];

    // #when
    const dispatch = dispatchableBlocks(two, rows({ review: red("b:review"), scan: red("b:scan") }), decisions({}));

    // #then an operator deciding the review gate is not shown the scan gate's
    // consequences
    expect(withheldByBlock(dispatch, "review")).toEqual(["commit"]);
    expect(withheldByBlock(dispatch, "scan")).toEqual(["open-pr"]);
  });

  test("a transitively withheld block traces back to the red block, not its withheld parent", () => {
    // #given a two-deep chain behind one red block
    const deep = [
      fb({ id: "fix", block: "work", waive: "approval" }),
      fb({ id: "commit", block: "commit-work", after: ["fix"] }),
      fb({ id: "open-pr", block: "pr", after: ["commit"] }),
    ];

    // #when
    const dispatch = dispatchableBlocks(deep, rows({ fix: red("b:fix") }), decisions({}));

    // #then both withheld blocks name the gate the operator can actually release
    expect(withheldByBlock(dispatch, "fix")).toEqual(["commit", "open-pr"]);
    expect(withheldByBlock(dispatch, "commit")).toEqual([]);
  });

  test("waive approval on one block does not waive another red block", () => {
    // #given two independent red blocks, only one of them waived
    const two = [
      fb({ id: "review", block: "code-review", waive: "approval" }),
      fb({ id: "scan", block: "secret-scan" }),
      fb({ id: "commit", block: "commit-work", after: ["review", "scan"] }),
    ];

    // #when
    const { dispatchable } = dispatchableBlocks(
      two,
      rows({ review: red("b:review"), scan: red("b:scan") }),
      decisions({ review: "approved" }),
    );

    // #then the un-waived one still withholds the shared successor
    expect(dispatchable.map((d) => d.block.id)).toEqual(["review", "scan"]);
  });
});

describe("epilogShouldRender", () => {
  const chain = [
    fb({ id: "scan", block: "secret-scan" }),
    fb({ id: "fix", block: "work", after: ["scan"] }),
  ];

  test("renders once every block has recorded a row", () => {
    // #given a clean run
    // #when / #then
    expect(epilogShouldRender(chain, rows({ scan: green("b:scan"), fix: green("b:fix") }))).toBe(true);
  });

  test("renders for a run a red gate stopped, whose later blocks never ran", () => {
    // #given the first block is red, so the second was withheld and has no row
    // #when / #then the outcome record and artifact archive are still written
    expect(epilogShouldRender(chain, rows({ scan: red("b:scan") }))).toBe(true);
  });

  test("renders for a run whose block crashed rather than reported", () => {
    // #given the guard's crash row is the only verdict there is
    // #when / #then
    expect(epilogShouldRender(chain, rows({ scan: red("b:scan-crashed", "non-terminal") }))).toBe(true);
  });

  test("does not render while the flow is still mid-run and green", () => {
    // #given the first block passed and the second has not reported
    // #when / #then rendering now would archive a run that is still working
    expect(epilogShouldRender(chain, rows({ scan: green("b:scan") }))).toBe(false);
  });

  test("does not render before any block has recorded anything", () => {
    // #given an empty run
    // #when / #then
    expect(epilogShouldRender(chain, rows({}))).toBe(false);
  });

  // The epilog is pushed into the render tree once per render pass under fixed
  // node ids, so the engine dedupes repeats. What would break "exactly once" is
  // the condition flipping back to false and re-rendering the epilog later at a
  // different position — so the condition has to be monotone as rows accumulate.
  test("stays true once true, as rows accumulate through a stopped run", () => {
    // #given the row set a stopped run passes through, in order
    const timeline: Array<Record<string, RecordedBlock>> = [
      {},
      { scan: green("b:scan") },
      { scan: green("b:scan"), fix: red("b:fix") },
    ];

    // #when the condition is evaluated at each step
    const rendered = timeline.map((snapshot) => epilogShouldRender(chain, rows(snapshot)));

    // #then it only ever turns on
    expect(rendered).toEqual([false, false, true]);
  });
});

describe("flowVerdict", () => {
  const chain = [
    fb({ id: "scan", block: "secret-scan" }),
    fb({ id: "fix", block: "work", after: ["scan"] }),
    fb({ id: "open-pr", block: "pr", after: ["fix"] }),
  ];

  test("a clean run reports completed and names nothing", () => {
    // #given every block green
    const dispatch = dispatchableBlocks(chain, rows({ scan: green("b:scan"), fix: green("b:fix"), "open-pr": green("b:open-pr") }));

    // #when / #then
    expect(flowVerdict(dispatch)).toEqual({ state: "completed", stoppedBy: null, summary: "no block gated red; nothing was withheld", withheld: [] });
  });

  test("a stopped run names the block that stopped it", () => {
    // #given a red block with a successor
    const dispatch = dispatchableBlocks(chain, rows({ scan: green("b:scan"), fix: red("b:fix") }));

    // #when
    const verdict = flowVerdict(dispatch);

    // #then an operator reads what happened instead of inferring it
    expect(verdict.state).toBe("stopped-by-red-gate");
    expect(verdict.stoppedBy).toBe("fix (work): failed");
    expect(verdict.summary).toContain('block "fix" (work)');
    expect(verdict.summary).toContain("1 downstream block never ran: open-pr");
  });

  test("a parked run is not reported as stopped", () => {
    // #given a red block awaiting its waive approval
    const parked = [fb({ id: "fix", block: "work", waive: "approval" }), fb({ id: "open-pr", block: "pr", after: ["fix"] })];
    const dispatch = dispatchableBlocks(parked, rows({ fix: red("b:fix") }), decisions({}));

    // #when / #then a parked run can still be released; the verdict says so
    expect(flowVerdict(dispatch).state).toBe("parked-for-waive-approval");
  });

  test("a hard stop outranks a park when both happened", () => {
    // #given one red block parked for approval and an independent hard stop
    const both = [
      fb({ id: "review", block: "code-review", waive: "approval" }),
      fb({ id: "scan", block: "secret-scan" }),
      fb({ id: "open-pr", block: "pr", after: ["review", "scan"] }),
    ];
    const dispatch = dispatchableBlocks(both, rows({ review: red("b:review"), scan: red("b:scan") }), decisions({}));

    // #when / #then the verdict leads with the outcome that cannot be released
    expect(flowVerdict(dispatch).state).toBe("stopped-by-red-gate");
    expect(flowVerdict(dispatch).stoppedBy).toBe("scan (secret-scan): failed");
  });

  test("a denied waive reads as a stop, not a park", () => {
    // #given the operator refused the waive
    const denied = [fb({ id: "fix", block: "work", waive: "approval" }), fb({ id: "open-pr", block: "pr", after: ["fix"] })];
    const dispatch = dispatchableBlocks(denied, rows({ fix: red("b:fix") }), decisions({ fix: "denied" }));

    // #when / #then
    expect(flowVerdict(dispatch).summary).toContain("stopped by a denied waive approval");
  });

  test("a red leaf block says nothing downstream was withheld", () => {
    // #given the last block in the flow went red
    const dispatch = dispatchableBlocks(chain, rows({ scan: green("b:scan"), fix: green("b:fix"), "open-pr": red("b:open-pr") }));

    // #when / #then the verdict does not imply successors were cut
    expect(flowVerdict(dispatch).summary).toContain("nothing downstream was left to withhold");
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
