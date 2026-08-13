import { describe, expect, test } from "bun:test";

import { isReservedBlockId, isValidBlockIdGrammar } from "./flow-spec.ts";
import { type RegistryBlockView, type RegistryView, validateFlowSpec, type ValidationError } from "./flow-validate.ts";

// A fake registry standing in for U2: the validator only needs schema
// identities, kinds, flags, and waive policies — never the block source.
const CATALOG: Record<string, RegistryBlockView> = {
  "secret-scan": { kind: "compute", external: false, publishes: false, needsWorkspace: true, inputSchemaId: "scan.in", outputSchemaId: "scan.out", waivePolicies: ["none"], scan: true },
  repro: { kind: "agent", external: false, publishes: false, needsWorkspace: true, inputSchemaId: "repro.in", outputSchemaId: "repro.out", waivePolicies: ["none", "approval"], scan: false },
  work: { kind: "agent", external: false, publishes: false, needsWorkspace: true, inputSchemaId: "repro.out", outputSchemaId: "work.out", waivePolicies: ["none", "approval"], scan: false },
  "code-review": { kind: "subflow", external: true, publishes: false, needsWorkspace: true, inputSchemaId: "work.out", outputSchemaId: "review.out", waivePolicies: ["none", "approval"], scan: false },
  pr: { kind: "agent", external: false, publishes: true, needsWorkspace: true, inputSchemaId: "review.out", outputSchemaId: "pr.out", waivePolicies: ["none"], scan: false },
};

const ADAPTERS = new Set<string>(["repro.out|scan.in", "work.out|scan.in", "scan.out|work.out"]);

const registry: RegistryView = {
  get: (name) => CATALOG[name],
  hasAdapter: (from, to) => ADAPTERS.has(`${from}|${to}`),
};

const deps = { registry, archiveExists: (id: string) => id === "run-abc" };

function block(over: Record<string, unknown> = {}): Record<string, unknown> {
  return { id: "b1", block: "repro", retries: 1, timeoutMs: 60_000, after: [], bindTo: [], ...over };
}

function spec(blocks: Array<Record<string, unknown>>, over: Record<string, unknown> = {}): Record<string, unknown> {
  return { task: { description: "fix a bug" }, repo: "/tmp/repo", blocks, ...over };
}

function invariants(errors: ValidationError[]): string[] {
  return errors.map((e) => e.invariant);
}

describe("validateFlowSpec", () => {
  test("valid bug-shaped spec passes and returns a normalized spec", () => {
    // #given a scan → work → external review → pr chain with binds
    const s = spec([
      block({ id: "scan", block: "secret-scan" }),
      block({ id: "repro", block: "repro", after: ["scan"] }),
      block({ id: "fix", block: "work", after: ["repro"], bindTo: ["repro"] }),
      block({ id: "review", block: "code-review", after: ["fix", "scan"], bindTo: ["fix"] }),
      block({ id: "open-pr", block: "pr", after: ["review"], bindTo: ["review"] }),
    ]);
    // #when validated
    const result = validateFlowSpec(s, deps);
    // #then it passes and normalizes optionals to concrete values
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.spec.blocks).toHaveLength(5);
      expect(result.spec.artifactsFrom).toBeNull();
      expect(result.spec.blocks[0].retries).toBe(1);
    }
  });

  test("a pr block without a preceding secret-scan is rejected, like an external leg", () => {
    // #given a flow that opens a PR with no scan ancestor. The pr block is not
    // `external` — it dispatches nothing to a vendor — but it publishes run
    // content, which reaches the same KTD13 surface.
    const s = spec([
      block({ id: "fix", block: "work" }),
      block({ id: "ship", block: "pr", after: ["fix"], bindTo: ["fix"] }),
    ]);

    // #when
    const result = validateFlowSpec(s, deps);

    // #then
    expect(result.ok).toBe(false);
    if (!result.ok) {
      const err = result.errors.find((e) => e.invariant === "scan-before-external");
      expect(err?.blockId).toBe("ship");
      expect(err?.hint).toContain("publishing block");
    }
  });

  test("a pr block with a secret-scan ancestor is accepted", () => {
    // #given the same flow with the scan inserted
    const s = spec([
      block({ id: "fix", block: "work" }),
      block({ id: "scan", block: "secret-scan", after: ["fix"], bindTo: ["fix"] }),
      block({ id: "ship", block: "pr", after: ["scan"], bindTo: ["scan"] }),
    ]);

    // #when / #then
    const result = validateFlowSpec(s, deps);
    const scanErrors = result.ok ? [] : result.errors.filter((e) => e.invariant === "scan-before-external");
    expect(scanErrors).toEqual([]);
  });

  test("AE1: external review without a preceding secret-scan is rejected naming the block", () => {
    // #given an external code-review with no scan ancestor
    const s = spec([
      block({ id: "fix", block: "work" }),
      block({ id: "review", block: "code-review", after: ["fix"], bindTo: ["fix"] }),
    ]);
    // #when validated
    const result = validateFlowSpec(s, deps);
    // #then it refuses and hints the scan insertion point
    expect(result.ok).toBe(false);
    if (!result.ok) {
      const err = result.errors.find((e) => e.invariant === "scan-before-external");
      expect(err?.blockId).toBe("review");
      expect(err?.hint).toContain("scan block");
    }
  });

  test("cycle in after edges is rejected", () => {
    const s = spec([
      block({ id: "a", block: "repro", after: ["b"] }),
      block({ id: "b", block: "repro", after: ["a"] }),
    ]);
    const result = validateFlowSpec(s, deps);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(invariants(result.errors)).toContain("cycle");
  });

  test("bindTo target that is not an after-ancestor is rejected", () => {
    const s = spec([
      block({ id: "scan", block: "secret-scan" }),
      block({ id: "fix", block: "work", after: ["scan"], bindTo: ["scan"] }),
      // binds to `fix` but has no `after` path to it
      block({ id: "repro", block: "repro", after: ["scan"], bindTo: ["fix"] }),
    ]);
    const result = validateFlowSpec(s, deps);
    expect(result.ok).toBe(false);
    if (!result.ok) {
      const err = result.errors.find((e) => e.invariant === "bind-unreachable");
      expect(err?.edge).toEqual(["repro", "fix"]);
    }
  });

  test("missing retries or timeoutMs is rejected naming the block", () => {
    const s = spec([
      block({ id: "no-retries", block: "repro", retries: undefined }),
      block({ id: "no-timeout", block: "work", after: ["no-retries"], bindTo: ["no-retries"], timeoutMs: undefined }),
    ]);
    const result = validateFlowSpec(s, deps);
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.errors.find((e) => e.invariant === "missing-retries")?.blockId).toBe("no-retries");
      expect(result.errors.find((e) => e.invariant === "missing-timeout")?.blockId).toBe("no-timeout");
    }
  });

  test("boundary schema mismatch without a declared adapter is rejected naming both blocks", () => {
    // #given pr (input review.out) binding directly to repro (output repro.out)
    const s = spec([
      block({ id: "repro", block: "repro" }),
      block({ id: "open-pr", block: "pr", after: ["repro"], bindTo: ["repro"] }),
    ]);
    const result = validateFlowSpec(s, deps);
    expect(result.ok).toBe(false);
    if (!result.ok) {
      const err = result.errors.find((e) => e.invariant === "boundary-schema");
      expect(err?.edge).toEqual(["repro", "open-pr"]);
    }
  });

  test("a declared edge adapter reconciles an otherwise-mismatched boundary", () => {
    // #given work (input repro.out) binding to a scan (output scan.out) via adapter scan.out|work.out... use repro->scan adapter
    const s = spec([
      block({ id: "repro", block: "repro" }),
      block({ id: "scan", block: "secret-scan", after: ["repro"], bindTo: ["repro"] }),
    ]);
    // repro.out -> scan.in is a declared adapter
    const result = validateFlowSpec(s, deps);
    expect(result.ok).toBe(true);
  });

  test("reserved-affix block id is rejected", () => {
    const s = spec([block({ id: "gate-x", block: "repro" })]);
    const r1 = validateFlowSpec(s, deps);
    expect(r1.ok).toBe(false);
    if (!r1.ok) expect(invariants(r1.errors)).toContain("reserved-id");

    const s2 = spec([block({ id: "fix-extra", block: "repro" })]);
    const r2 = validateFlowSpec(s2, deps);
    expect(r2.ok).toBe(false);
    if (!r2.ok) expect(invariants(r2.errors)).toContain("reserved-id");
  });

  test("inline command string in an exec-typed input field is rejected (KTD15)", () => {
    const s = spec([block({ id: "fix", block: "work", input: { setupCmd: "rm -rf /" } })]);
    const result = validateFlowSpec(s, deps);
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.errors.find((e) => e.invariant === "command-provenance")?.blockId).toBe("fix");
    }
  });

  test("an operator-source command reference passes provenance", () => {
    const s = spec([block({ id: "fix", block: "work", input: { setupCmd: "flag:--setup-cmd" } })]);
    const result = validateFlowSpec(s, deps);
    expect(result.ok).toBe(true);
  });

  test("artifactsFrom pointing at a missing archive is rejected", () => {
    const s = spec([block({ id: "repro", block: "repro" })], { artifactsFrom: "run-missing" });
    const result = validateFlowSpec(s, deps);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(invariants(result.errors)).toContain("artifacts-missing");
  });

  test("artifactsFrom that resolves is accepted", () => {
    const s = spec([block({ id: "repro", block: "repro" })], { artifactsFrom: "run-abc" });
    const result = validateFlowSpec(s, deps);
    expect(result.ok).toBe(true);
  });

  test("unknown catalog block is rejected", () => {
    const s = spec([block({ id: "mystery", block: "does-not-exist" })]);
    const result = validateFlowSpec(s, deps);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(invariants(result.errors)).toContain("unknown-block");
  });

  test("waive policy invalid for the block kind is rejected", () => {
    const s = spec([block({ id: "scan", block: "secret-scan", waive: "approval" })]);
    const result = validateFlowSpec(s, deps);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(invariants(result.errors)).toContain("waive-policy");
  });
});

describe("block id helpers", () => {
  test("grammar accepts lowercase kebab and rejects others", () => {
    expect(isValidBlockIdGrammar("repro-fix")).toBe(true);
    expect(isValidBlockIdGrammar("Repro")).toBe(false);
    expect(isValidBlockIdGrammar("a--b")).toBe(false);
    expect(isValidBlockIdGrammar("-a")).toBe(false);
  });

  test("reserved affixes are flagged", () => {
    expect(isReservedBlockId("gate-a")).toBe(true);
    expect(isReservedBlockId("a-crashed")).toBe(true);
    expect(isReservedBlockId("staging")).toBe(true);
    expect(isReservedBlockId("repro")).toBe(false);
  });
});
