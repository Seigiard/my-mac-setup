import { describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as path from "node:path";

import sePipeline from "../se-pipeline.tsx";
import seSimplify from "../se-simplify.tsx";

// The pipeline's simplify wiring is orchestration inside a smithers render, not
// a pure function — the repo tests pure decisions in lib/ (see stage-gate.test:
// shouldRunSimplify + simplifyCommitDecision) and transpile-checks workflows by
// importing them. These cases pin the STRUCTURAL contract the render must hold:
// verify-doc is conditional, simplify sits after secret-scan and before
// verify-code, its commit + rescan land before verify-code, and the subflow
// targets the run worktree. Deterministic source assertions + a load check —
// the live render is exercised by the pipeline smoke run (Verification Contract).
const pipelineSrc = fs.readFileSync(path.join(import.meta.dir, "..", "se-pipeline.tsx"), "utf8");

const idxOf = (needle: string): number => {
  const i = pipelineSrc.indexOf(needle);
  expect(i, `expected to find ${needle} in se-pipeline.tsx`).toBeGreaterThanOrEqual(0);
  return i;
};

describe("se-pipeline transpiles / loads", () => {
  test("both workflows import and expose a workflow definition", () => {
    expect(sePipeline).toBeDefined();
    expect(seSimplify).toBeDefined();
  });
});

describe("docReview gating (R7)", () => {
  test("inputSchema declares docReview defaulting to false", () => {
    expect(pipelineSrc).toMatch(/docReview[\s\S]{0,160}\.default\(false\)/);
  });

  test("verify-doc renders only inside the docReview branch, work falls through otherwise", () => {
    // #then the verify-doc stageBlock is gated on input.docReview
    const gate = idxOf("if (input.docReview) {");
    const verifyDocStage = idxOf('name: "verify-doc"');
    expect(verifyDocStage).toBeGreaterThan(gate);
    // #and there is an else that lets work run without plan-review
    expect(pipelineSrc).toContain("docGreen = true");
  });
});

describe("simplify stage placement (R7/R9/KTD-H)", () => {
  test("simplify subflow sits AFTER secret-scan and BEFORE verify-code", () => {
    const secretScan = idxOf('name: "secret-scan"');
    const simplify = idxOf('id="simplify"');
    const verifyCode = idxOf('name: "verify-code"');
    expect(simplify).toBeGreaterThan(secretScan);
    expect(simplify).toBeLessThan(verifyCode);
  });

  test("simplify commit + rescan land before verify-code", () => {
    const commit = idxOf('id="simplify-commit"');
    const rescan = idxOf('name: "simplify-rescan"');
    const verifyCode = idxOf('name: "verify-code"');
    expect(commit).toBeLessThan(verifyCode);
    expect(rescan).toBeLessThan(verifyCode);
  });

  test("the simplify subflow targets the run worktree, never the operator repo", () => {
    // #then the simplify Subflow input binds repoPath to the isolated worktree
    // (gate0 keeps its own repoPath:repoDir for the launch checkout — that is the
    // operator repo, not the simplify apply target; so scope the check to the
    // simplify Subflow block).
    const simplifyBlock = pipelineSrc.slice(idxOf('id="simplify"'), idxOf('id="simplify"') + 400);
    expect(simplifyBlock).toContain("repoPath: staged.worktreePath");
    expect(simplifyBlock).not.toContain("repoPath: repoDir");
  });

  test("verify-code is gated on simplify readiness", () => {
    const simplifyReady = idxOf("if (simplifyReady) {");
    const verifyCodeStage = idxOf('name: "verify-code"');
    expect(verifyCodeStage).toBeGreaterThan(simplifyReady);
  });
});
