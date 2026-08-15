import { afterAll, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { type AgentBlockDefinition, catalogToJson } from "../block-registry.ts";
import { workEnvelopeSchema } from "../envelopes.ts";
import { withStagedPlanPath } from "../flow-run.ts";
import { planContentHash } from "../gates.ts";
import { resolveStagedPlans, stageRunPlan } from "../staging.ts";
import { validateFlowSpec } from "../flow-validate.ts";
import { buildRegistry, INITIAL_LIBRARY } from "./index.ts";

const registry = buildRegistry();
const deps = { registry: registry.view(), archiveExists: () => true };

function agentBlock(name: string): AgentBlockDefinition {
  const def = registry.get(name);
  if (def?.kind !== "agent") throw new Error(`"${name}" is not an agent block`);
  return def;
}

describe("initial block library", () => {
  test("registers every block from the initial library", () => {
    expect(registry.list().map((b) => b.name)).toEqual(
      [...INITIAL_LIBRARY].map((b) => b.name).sort((a, b) => a.localeCompare(b)),
    );
  });

  test("catalog is byte-stable across generations", () => {
    expect(catalogToJson(registry)).toBe(catalogToJson(registry));
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

const tempDirs: string[] = [];

function tempDir(prefix: string): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

afterAll(() => {
  for (const dir of tempDirs) fs.rmSync(dir, { recursive: true, force: true });
});

// Every agent block gates on envelopeComplete, which parses `report` with
// workEnvelopeSchema. On run-1786777192782 the agent answered in prose and the
// block gated red over correct work, so what the prompt asks for is the fix.
describe("agent block prompts state the return-to-caller envelope", () => {
  const promptCases: { name: string; prompt: string }[] = [
    { name: "work (planPath branch)", prompt: agentBlock("work").buildPrompt({ planPath: "/repo/docs/plans/p.md", prompt: null }) },
    { name: "work (prompt branch)", prompt: agentBlock("work").buildPrompt({ planPath: null, prompt: "lowercase the slug" }) },
    { name: "repro", prompt: agentBlock("repro").buildPrompt({ description: "crash on empty input" }) },
    { name: "analysis", prompt: agentBlock("analysis").buildPrompt({ question: "why is it slow" }) },
    { name: "subtasks", prompt: agentBlock("subtasks").buildPrompt({ scope: "the importer" }) },
  ];

  for (const { name, prompt } of promptCases) {
    test(`${name} names every field of workEnvelopeSchema`, () => {
      // #given the schema parseWorkEnvelope judges the answer with
      const fields = Object.keys(workEnvelopeSchema.shape);

      // #when / #then the prompt names each one, so prompt and parser cannot drift
      expect(fields.filter((field) => !prompt.includes(field))).toEqual([]);
    });

    test(`${name} asks for the {"report": "<envelope>"} wrapper explicitly`, () => {
      // #given makeWorkAgent's jsonSchema constrains only the wrapper
      // #when / #then the string's contents are asked for in the prompt instead
      expect(prompt).toContain(`{"report": "<the ce-work return-to-caller envelope, itself serialized as a JSON STRING>"}`);
    });
  }
});

describe("the work block's plan path", () => {
  const planBody = "---\nartifact_readiness: implementation-ready\nexecution: code\n---\n\n# Plan\n";

  test("the prompt names the frozen copy, never the operator's checkout path", () => {
    // #given a plan in the operator's checkout, frozen for one run
    const branch = "se/fix-thing-1234abcd";
    const baseDir = tempDir("blocks-base-");
    const planPath = path.join(tempDir("blocks-checkout-"), "2026-08-15-fix-thing.md");
    fs.writeFileSync(planPath, planBody);
    const planHash = planContentHash(planBody);
    const copyPath = stageRunPlan(planPath, branch, planHash, { worktreeBaseDir: baseDir });
    const resolved = resolveStagedPlans([{ blockId: "fix", planPath, planHash, copyPath }], branch, { worktreeBaseDir: baseDir });
    const resolution = resolved.fix;
    if (!resolution?.ok) throw new Error("expected the frozen copy to resolve");

    // #when the interpreter substitutes before building the prompt
    const prompt = agentBlock("work").buildPrompt(withStagedPlanPath({ planPath, prompt: null }, resolution.copyPath));

    // #then the launcher's path never reaches the agent (run-1786717826270)
    expect(prompt).toContain(copyPath);
    expect(prompt).not.toContain(planPath);
  });

  test("with no staged copy the prompt keeps the operator's path", () => {
    // #given a flow that needs no workspace: nothing is staged, so
    // resolveStagedPlans reports nothing for the block
    const planPath = "/repo/docs/plans/2026-08-15-fix-thing.md";
    const input = { planPath, prompt: null };
    const resolution = resolveStagedPlans([], "").fix;

    // #when the interpreter has no substitution to make (its own expression)
    const prompt = agentBlock("work").buildPrompt(resolution?.ok ? withStagedPlanPath(input, resolution.copyPath) : input);

    // #then there is no isolation to protect and the operator's path stands
    expect(prompt).toContain(planPath);
  });

  test("tells the agent every repository path belongs to its cwd", () => {
    // #given the plan path the prompt embeds is concrete and absolute
    const prompt = agentBlock("work").buildPrompt({ planPath: "/tmp/se-pipeline/se-fix-1234abcd-plan/p.md", prompt: null });

    // #when / #then the prose that lost to it on run-1786717826270 is present
    expect(prompt).toContain("EVERY repository path you resolve, read, or write belongs to your cwd");
  });
});
