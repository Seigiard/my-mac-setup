import { describe, expect, test } from "bun:test";

import { catalogToJson } from "../block-registry.ts";
import { validateFlowSpec } from "../flow-validate.ts";
import { buildRegistry, INITIAL_LIBRARY } from "./index.ts";

const registry = buildRegistry();
const deps = { registry: registry.view(), archiveExists: () => true };

describe("initial block library", () => {
  test("registers every block from the initial library", () => {
    expect(registry.list().map((b) => b.name)).toEqual(
      [...INITIAL_LIBRARY].map((b) => b.name).sort((a, b) => a.localeCompare(b)),
    );
  });

  test("catalog is byte-stable across independently built registries", () => {
    // Comparing one registry's JSON to itself could never fail. Two separate
    // buildRegistry() calls redden this if the catalog ever gains
    // per-instance or per-generation content (timestamps, ids, unstable
    // iteration order).
    expect(catalogToJson(buildRegistry())).toBe(catalogToJson(registry));
  });

  test("catalog exposes external and needsWorkspace flags per block", () => {
    const catalog = registry.catalog();
    expect(catalog.find((c) => c.name === "code-review")?.external).toBe(true);
    expect(catalog.find((c) => c.name === "doc-review")?.needsWorkspace).toBe(false);
    expect(catalog.find((c) => c.name === "secret-scan")?.scan).toBe(true);
  });

  test("a bug-shaped spec validates against the real registry (F1)", () => {
    const spec = {
      task: { description: "fix the crash on empty input", classification: "bug" },
      repo: "/tmp/repo",
      blocks: [
        { id: "scan", block: "secret-scan", retries: 0, timeoutMs: 120000 },
        { id: "reproduce", block: "repro", retries: 1, timeoutMs: 600000, after: ["scan"], bindTo: ["scan"] },
        { id: "fix", block: "work", retries: 1, timeoutMs: 600000, after: ["reproduce"], bindTo: ["reproduce"] },
        { id: "commit", block: "commit-work", retries: 0, timeoutMs: 60000, after: ["fix"], bindTo: ["fix"] },
        { id: "validate", block: "run-validate", input: { validateCmd: "flag:--validate-cmd" }, retries: 0, timeoutMs: 600000, after: ["commit"], bindTo: ["commit"] },
        { id: "review", block: "code-review", retries: 0, timeoutMs: 2700000, after: ["validate", "scan"], bindTo: ["validate"] },
        { id: "artifacts", block: "proof-artifacts", input: { names: ["repro-log"] }, retries: 0, timeoutMs: 60000, after: ["review"], bindTo: ["review"] },
        { id: "open-pr", block: "pr", input: { title: "Fix crash on empty input" }, retries: 0, timeoutMs: 300000, after: ["artifacts"], bindTo: ["artifacts"] },
      ],
    };
    const result = validateFlowSpec(spec, deps);
    if (!result.ok) throw new Error(`expected valid, got: ${JSON.stringify(result.errors, null, 2)}`);
    expect(result.ok).toBe(true);
  });

  test("a research spec with no workspace-needing block still validates (workspace-free flow)", () => {
    const spec = {
      task: { description: "compare two libraries", classification: "research" },
      repo: "/tmp/repo",
      blocks: [
        { id: "scan", block: "secret-scan", retries: 0, timeoutMs: 120000 },
        { id: "review-doc", block: "doc-review", input: { planPath: "docs/plans/x.md" }, retries: 1, timeoutMs: 1500000, after: ["scan"], bindTo: ["scan"] },
      ],
    };
    const result = validateFlowSpec(spec, deps);
    expect(result.ok).toBe(true);
  });

  test("an external review with no preceding secret-scan is refused against the real registry (AE1)", () => {
    const spec = {
      task: { description: "review only", classification: "feature" },
      repo: "/tmp/repo",
      blocks: [{ id: "review", block: "code-review", retries: 0, timeoutMs: 120000 }],
    };
    const result = validateFlowSpec(spec, deps);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.errors.map((e) => e.invariant)).toContain("scan-before-external");
  });
});
