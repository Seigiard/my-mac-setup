import { describe, expect, test } from "bun:test";
import type { ClaudeCodeAgent } from "smithers-orchestrator";
import { z } from "zod/v4";

import {
  type AgentBlockDefinition,
  BlockRegistry,
  catalogToJson,
  type ComputeBlockDefinition,
} from "./block-registry.ts";
import type { GateResult } from "./gates.ts";

const green: GateResult = { state: "green", reasons: [] };

function computeBlock(over: Partial<ComputeBlockDefinition> = {}): ComputeBlockDefinition {
  return {
    name: "secret-scan",
    kind: "compute",
    purpose: "scan the run diff for secrets",
    inputSchema: z.object({ baseSha: z.string() }),
    outputSchema: z.object({ state: z.string() }),
    inputSchemaId: "scan.in",
    outputSchemaId: "scan.out",
    external: false,
    needsWorkspace: true,
    scan: true,
    preconditions: [],
    waivePolicies: ["none"],
    defaults: { retries: 0, timeoutMs: 120_000 },
    costProfile: { estUsd: 0 },
    gateFn: () => green,
    ...over,
  };
}

function agentBlock(over: Partial<AgentBlockDefinition> = {}): AgentBlockDefinition {
  return {
    name: "repro",
    kind: "agent",
    purpose: "reproduce the reported bug",
    inputSchema: z.object({ description: z.string() }),
    outputSchema: z.object({ reproduced: z.boolean() }),
    inputSchemaId: "repro.in",
    outputSchemaId: "repro.out",
    external: false,
    needsWorkspace: true,
    scan: false,
    preconditions: [],
    waivePolicies: ["none", "approval"],
    defaults: { retries: 1, timeoutMs: 600_000 },
    costProfile: { estUsd: 3 },
    gateFn: () => green,
    // These tests register and read definitions; they never dispatch one, so a
    // stub stands in for the agent the interpreter would build.
    makeAgent: () => ({}) as unknown as ClaudeCodeAgent,
    buildPrompt: (input) => `repro: ${JSON.stringify(input)}`,
    ...over,
  };
}

describe("BlockRegistry catalog", () => {
  test("catalog round-trips every entry with schemas, kind, flags, defaults", () => {
    const registry = new BlockRegistry();
    registry.register(computeBlock());
    registry.register(agentBlock());
    const catalog = registry.catalog();
    expect(catalog.map((c) => c.name)).toEqual(["repro", "secret-scan"]);
    const scan = catalog.find((c) => c.name === "secret-scan");
    expect(scan?.needsWorkspace).toBe(true);
    expect(scan?.scan).toBe(true);
    expect(scan?.external).toBe(false);
    expect(scan?.defaults).toEqual({ retries: 0, timeoutMs: 120_000 });
    expect((scan?.inputSchema as { type?: string }).type).toBe("object");
    expect((scan?.outputSchema as { type?: string }).type).toBe("object");
  });

  test("catalog JSON is byte-stable across independently built registries", () => {
    // #given two registries holding the same blocks registered in opposite
    // order. Comparing one registry's JSON to itself could never fail — the
    // claim the test name makes is that generation order does not leak into
    // the bytes.
    const first = new BlockRegistry();
    first.register(agentBlock());
    first.register(computeBlock());

    const second = new BlockRegistry();
    second.register(computeBlock());
    second.register(agentBlock());

    // #then registration order is erased by list()'s sort
    expect(catalogToJson(first)).toBe(catalogToJson(second));
  });
});

describe("BlockRegistry compatibility", () => {
  test("identical schema ids accepted, mismatched pair refused, declared adapter reconciles", () => {
    const registry = new BlockRegistry();
    expect(registry.compatible("work.out", "work.out")).toBe(true);
    expect(registry.compatible("work.out", "scan.in")).toBe(false);
    registry.declareAdapter("work.out", "scan.in");
    expect(registry.compatible("work.out", "scan.in")).toBe(true);
  });

  test("the validator view exposes get and hasAdapter", () => {
    const registry = new BlockRegistry();
    registry.register(agentBlock());
    registry.declareAdapter("a", "b");
    const view = registry.view();
    expect(view.get("repro")?.kind).toBe("agent");
    expect(view.get("missing")).toBeUndefined();
    expect(view.hasAdapter("a", "b")).toBe(true);
  });
});

describe("BlockRegistry registration guards", () => {
  test("a compute block with a waive policy invalid for its kind is rejected", () => {
    const registry = new BlockRegistry();
    expect(() => registry.register(computeBlock({ waivePolicies: ["approval"] }))).toThrow(/waive policy/);
  });

  test("an external block without a data-sharing contract is rejected", () => {
    const registry = new BlockRegistry();
    expect(() => registry.register(agentBlock({ name: "ext-review", external: true }))).toThrow(/data-sharing contract/);
  });

  test("an external block with a contract registers", () => {
    const registry = new BlockRegistry();
    registry.register(
      agentBlock({ name: "ext-review", external: true, externalContract: { dispatchScan: true, invocation: "read-only-external-agent" } }),
    );
    expect(registry.get("ext-review")?.external).toBe(true);
  });

  test("a duplicate registration is rejected", () => {
    const registry = new BlockRegistry();
    registry.register(agentBlock());
    expect(() => registry.register(agentBlock())).toThrow(/already registered/);
  });
});
