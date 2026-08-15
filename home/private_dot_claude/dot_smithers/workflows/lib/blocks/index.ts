// Initial block library (U3 carved stages + U9 new shapes). Every entry is a
// typed registry block the orchestrator composes from and the interpreter
// dispatches. Gate functions are pure classification of recorded output (KTD4);
// agent blocks carry buildPrompt + makeAgent (KTD3); subflow blocks carry a
// closed mirror key (KTD3). se-pipeline.tsx is untouched — these wrap the same
// lib functions so both the fixed pipeline and the composable flow share one
// implementation of each behavior (R3), the pipeline keeping its own copy for
// KD6's rollback path.
import type { ClaudeCodeAgent } from "smithers-orchestrator";
import { z } from "zod/v4";

import { makeWorkAgent } from "../agents.ts";
import {
  type AgentBlockDefinition,
  BlockRegistry,
  type ComputeBlockDefinition,
  type ExternalContract,
  type SubflowBlockDefinition,
} from "../block-registry.ts";
import { parseWorkEnvelope, workEnvelopeSchema } from "../envelopes.ts";
import { codeReviewGate, type GateResult, rescanGate } from "../gates.ts";

const EXTERNAL_CONTRACT: ExternalContract = { dispatchScan: true, invocation: "read-only-ask-agent" };

const green: GateResult = { state: "green", reasons: [] };
function red(reason: string): GateResult {
  return { state: "failed", reasons: [reason] };
}

// Shared handoff shape: every block records its result into the generic
// blockOutput table (KTD3), so downstream consumers read a normalized handoff
// row. Boundary compatibility keys on these ids; the initial library declares
// adapters for the canonical cross-kind edges below.
const HANDOFF_IN = "flow.handoff.in";
const HANDOFF_OUT = "flow.handoff.out";

// ---- Compute blocks (effectful steps; the interpreter runs the effect) -------

const secretScan: ComputeBlockDefinition = {
  name: "secret-scan",
  kind: "compute",
  purpose: "Scan the run diff for committed secrets before any external leg or publish (R6/KTD13).",
  // No input: the scan base is the staged worktree's own base, never spec data.
  // A composer-supplied base could name HEAD and reduce the scan to an empty
  // commit range that reports clean.
  inputSchema: z.object({}),
  outputSchema: z.object({ state: z.enum(["clean", "found", "error"]), details: z.string() }),
  inputSchemaId: HANDOFF_IN,
  outputSchemaId: HANDOFF_OUT,
  external: false,
  needsWorkspace: true,
  scan: true,
  preconditions: ["a staged worktree with the run's commits"],
  waivePolicies: ["none"],
  defaults: { retries: 0, timeoutMs: 2 * 60_000 },
  costProfile: { estUsd: 0 },
  gateFn: (recorded) => {
    const state = (recorded as { state?: string })?.state;
    return state === "clean" ? green : red(`secret scan reported "${state ?? "no result"}" — a leak or scanner error is never a pass`);
  },
};

const rescan: ComputeBlockDefinition = {
  name: "rescan",
  kind: "compute",
  purpose: "Re-scan and re-validate operator commits added during an approval pause (R6).",
  // No input: what counts as an operator commit is the interpreter's pause-head
  // record, not spec data.
  inputSchema: z.object({}),
  outputSchema: z.object({ moved: z.boolean() }).loose(),
  inputSchemaId: HANDOFF_IN,
  outputSchemaId: HANDOFF_OUT,
  external: false,
  needsWorkspace: true,
  scan: true,
  preconditions: ["a prior approval pause on this run"],
  waivePolicies: ["none"],
  defaults: { retries: 0, timeoutMs: 3 * 60_000 },
  costProfile: { estUsd: 0 },
  gateFn: (recorded) => rescanGate({ raw: JSON.stringify(recorded) }),
};

const commitWork: ComputeBlockDefinition = {
  name: "commit-work",
  kind: "compute",
  purpose: "Commit staged agent changes; records base/head tree hashes for the work gate (KTD4).",
  inputSchema: z.object({}),
  outputSchema: z.object({ baseTree: z.string(), headTree: z.string(), committed: z.boolean() }),
  inputSchemaId: HANDOFF_IN,
  outputSchemaId: HANDOFF_OUT,
  external: false,
  needsWorkspace: true,
  scan: false,
  preconditions: ["a preceding work block"],
  waivePolicies: ["none"],
  defaults: { retries: 0, timeoutMs: 60_000 },
  costProfile: { estUsd: 0 },
  gateFn: (recorded) => {
    const out = recorded as { baseTree?: string; headTree?: string };
    return out?.baseTree && out.headTree && out.baseTree !== out.headTree
      ? green
      : red("worktree tree hash equals base — no content change (KTD14)");
  },
};

const runValidate: ComputeBlockDefinition = {
  name: "run-validate",
  kind: "compute",
  purpose: "Run the operator-supplied validate-cmd on the run commit; records its exit code (KTD3/KTD15).",
  // No input: the command comes from the run's launch flags. A spec that could
  // name it would define what "verified" means for its own run.
  inputSchema: z.object({}),
  outputSchema: z.object({ exitCode: z.number().nullish(), output: z.string() }),
  inputSchemaId: HANDOFF_IN,
  outputSchemaId: HANDOFF_OUT,
  external: false,
  needsWorkspace: true,
  scan: false,
  preconditions: ["an operator-supplied validate-cmd on the run"],
  waivePolicies: ["none"],
  defaults: { retries: 0, timeoutMs: 10 * 60_000 },
  costProfile: { estUsd: 0 },
  gateFn: (recorded) => {
    const code = (recorded as { exitCode?: number | null })?.exitCode;
    if (code === null || code === undefined) return red("validate-cmd was not executed — self-report is not ground truth (KTD3)");
    return code === 0 ? green : red(`validate-cmd exited with code ${code}`);
  },
};

const proofArtifacts: ComputeBlockDefinition = {
  name: "proof-artifacts",
  kind: "compute",
  purpose: "Collect named outputs into the run artifact manifest consumed by the outcome record (R11/KTD10).",
  inputSchema: z.object({ names: z.array(z.string()).default([]) }),
  outputSchema: z.object({ manifest: z.array(z.object({ name: z.string(), path: z.string() })) }),
  inputSchemaId: HANDOFF_IN,
  outputSchemaId: HANDOFF_OUT,
  external: false,
  needsWorkspace: true,
  scan: false,
  preconditions: [],
  waivePolicies: ["none"],
  defaults: { retries: 0, timeoutMs: 60_000 },
  costProfile: { estUsd: 0 },
  gateFn: (recorded) => (Array.isArray((recorded as { manifest?: unknown })?.manifest) ? green : red("proof-artifacts produced no manifest")),
};

const pr: ComputeBlockDefinition = {
  name: "pr",
  kind: "compute",
  purpose: "Push the run-id branch through the pre-push guard and open a PR embedding spec + outcome record (R11/KTD11/KTD13).",
  inputSchema: z.object({ title: z.string(), draft: z.boolean().default(false) }),
  outputSchema: z.object({ result: z.enum(["opened", "exists", "unauthenticated", "push-rejected"]), url: z.string().nullish(), redactionHits: z.array(z.string()).default([]) }),
  inputSchemaId: HANDOFF_IN,
  outputSchemaId: HANDOFF_OUT,
  external: false,
  // Pushes a branch and opens a PR: run content leaves the worktree for a
  // durable public target, so the validator requires a scan ancestor (KTD13).
  publishes: true,
  needsWorkspace: true,
  scan: false,
  preconditions: ["a run-id branch with commits"],
  waivePolicies: ["none"],
  defaults: { retries: 0, timeoutMs: 5 * 60_000 },
  costProfile: { estUsd: 0 },
  gateFn: (recorded) => {
    const result = (recorded as { result?: string })?.result;
    switch (result) {
      case "opened":
      case "exists":
        return green;
      case "unauthenticated":
        return red("gh is unauthenticated — cannot open the PR");
      case "push-rejected":
        return red("push to the run-id branch was rejected");
      default:
        return red(`pr block produced an unknown result "${result ?? "none"}"`);
    }
  },
};

// ---- Agent blocks (prompt-defined; the interpreter dispatches makeAgent) ------

function implementationAgent(build: { worktreePath: string; timeoutMs: number; budgetUsd: number }): ClaudeCodeAgent {
  return makeWorkAgent({ cwd: build.worktreePath, timeoutMs: build.timeoutMs, maxBudgetUsd: build.budgetUsd, jsonField: "report" });
}

// Read off workEnvelopeSchema rather than hand-copied: the prompt that asks for
// the envelope and the parser that judges it must name the same shape, and a
// field added to one with the other left behind is how they drift apart.
const ENVELOPE_FIELDS = Object.keys(workEnvelopeSchema.shape).join(", ");

// Every agent block below gates on envelopeComplete, and makeWorkAgent's
// jsonSchema constrains only the {report: string} wrapper — deliberately, so a
// malformed answer becomes a readable red row instead of an INVALID_OUTPUT task
// failure that skips the work that should still happen
// (docs/issues/2026-08-14-004). What the wrapper therefore does not enforce has
// to be ASKED for: on run-1786777192782 the agent implemented the plan
// correctly, answered in prose, parseWorkEnvelope refused it, and the block
// gated red over correct work. se-pipeline's workPrompt has always spelled the
// envelope out key by key and has never failed this way.
const ENVELOPE_CONTRACT = `

Your FINAL message must be EXACTLY one JSON object and nothing else: {"report": "<the ce-work return-to-caller envelope, itself serialized as a JSON STRING>"}. The envelope's fields: ${ENVELOPE_FIELDS}. A prose summary in "report" fails the gate however good the work was. The gate also requires status="complete" and a non-empty verification_evidence, so a run you cannot evidence is not complete.`;

function envelopeComplete(recorded: unknown): GateResult {
  const raw = (recorded as { report?: string })?.report ?? (typeof recorded === "string" ? recorded : undefined);
  const parsed = parseWorkEnvelope(raw);
  if (!parsed.ok) return red(`agent envelope unreadable: ${parsed.reason}`);
  if (parsed.envelope.status !== "complete") return red(`agent status is "${parsed.envelope.status}", expected "complete"`);
  if (parsed.envelope.verification_evidence.length === 0) return red("verification_evidence is empty — self-report has no proof");
  return green;
}

const work: AgentBlockDefinition = {
  name: "work",
  kind: "agent",
  purpose: "Implement a plan or bounded work prompt headless, returning the return-to-caller envelope (R2/R3).",
  inputSchema: z.object({ planPath: z.string().nullish(), prompt: z.string().nullish() }),
  outputSchema: z.object({ report: z.string() }),
  inputSchemaId: HANDOFF_IN,
  outputSchemaId: HANDOFF_OUT,
  external: false,
  needsWorkspace: true,
  scan: false,
  preconditions: ["a staged worktree"],
  waivePolicies: ["none", "approval"],
  defaults: { retries: 1, timeoutMs: 4 * 60 * 60_000 },
  costProfile: { estUsd: 20 },
  gateFn: envelopeComplete,
  makeAgent: implementationAgent,
  // The planPath this renders is whatever the interpreter substituted into the
  // input — the frozen run copy when one was staged (se-flow.tsx), never the
  // launcher's path by choice of this function. The prose guard rides along
  // because a concrete absolute path beats prose only when the prose is absent:
  // on run-1786717826270 the agent resolved every repository path against the
  // plan's own repository and wrote its work into the operator's checkout.
  buildPrompt: (input) => {
    const i = input as { planPath?: string | null; prompt?: string | null };
    const task = i.planPath
      ? `Invoke the skill compound-engineering:ce-work with args "mode:return-to-caller ${i.planPath}".

That plan file is an INPUT, not a location. Read it for its content and nothing else: never resolve a path relative to it, never write to it. EVERY repository path you resolve, read, or write belongs to your cwd.`
      : `Implement headless: ${i.prompt ?? ""}`;
    return `${task}${ENVELOPE_CONTRACT}`;
  },
};

const repro: AgentBlockDefinition = {
  name: "repro",
  kind: "agent",
  purpose: "Reproduce a reported bug from a failing proof before any fix (R2, bug shape).",
  inputSchema: z.object({ description: z.string() }),
  outputSchema: z.object({ report: z.string() }),
  inputSchemaId: HANDOFF_IN,
  outputSchemaId: HANDOFF_OUT,
  external: false,
  needsWorkspace: true,
  scan: false,
  preconditions: ["a staged worktree"],
  waivePolicies: ["none", "approval"],
  defaults: { retries: 1, timeoutMs: 60 * 60_000 },
  costProfile: { estUsd: 8 },
  gateFn: envelopeComplete,
  makeAgent: implementationAgent,
  buildPrompt: (input) => `Reproduce this bug with a failing check, headless: ${(input as { description?: string }).description ?? ""}${ENVELOPE_CONTRACT}`,
};

const analysis: AgentBlockDefinition = {
  name: "analysis",
  kind: "agent",
  purpose: "Analyze a reproduced failure or research question and record findings (R2, bug/research shape).",
  inputSchema: z.object({ question: z.string() }),
  outputSchema: z.object({ report: z.string() }),
  inputSchemaId: HANDOFF_IN,
  outputSchemaId: HANDOFF_OUT,
  external: false,
  needsWorkspace: true,
  scan: false,
  preconditions: [],
  waivePolicies: ["none", "approval"],
  defaults: { retries: 1, timeoutMs: 60 * 60_000 },
  costProfile: { estUsd: 8 },
  gateFn: envelopeComplete,
  makeAgent: implementationAgent,
  buildPrompt: (input) => `Analyze headless and record findings: ${(input as { question?: string }).question ?? ""}${ENVELOPE_CONTRACT}`,
};

const subtasks: AgentBlockDefinition = {
  name: "subtasks",
  kind: "agent",
  purpose: "Break an analyzed problem into bounded implementation subtasks (R2).",
  inputSchema: z.object({ scope: z.string() }),
  outputSchema: z.object({ report: z.string() }),
  inputSchemaId: HANDOFF_IN,
  outputSchemaId: HANDOFF_OUT,
  external: false,
  needsWorkspace: true,
  scan: false,
  preconditions: [],
  waivePolicies: ["none", "approval"],
  defaults: { retries: 1, timeoutMs: 30 * 60_000 },
  costProfile: { estUsd: 5 },
  gateFn: envelopeComplete,
  makeAgent: implementationAgent,
  buildPrompt: (input) => `Decompose into bounded subtasks headless: ${(input as { scope?: string }).scope ?? ""}${ENVELOPE_CONTRACT}`,
};

// ---- Subflow blocks (dual-mode Subflows; KTD3 mirror keys) -------------------

const codeReview: SubflowBlockDefinition = {
  name: "code-review",
  kind: "subflow",
  purpose: "Multi-leg code review of the run diff (external legs); merged envelope gates on P0 (R2/R6).",
  inputSchema: z.object({ base: z.string().nullish() }),
  outputSchema: z.object({ findings: z.array(z.unknown()), legs: z.record(z.string(), z.string()).nullish() }),
  inputSchemaId: HANDOFF_IN,
  outputSchemaId: HANDOFF_OUT,
  external: true,
  needsWorkspace: true,
  scan: false,
  preconditions: ["a secret-scan ancestor (validator-enforced)"],
  waivePolicies: ["none", "approval"],
  defaults: { retries: 0, timeoutMs: 45 * 60_000 },
  costProfile: { estUsd: 15 },
  gateFn: (recorded) => codeReviewGate({ raw: JSON.stringify(recorded) }),
  externalContract: EXTERNAL_CONTRACT,
  mirrorKey: "reviewLeg",
  buildSubflowInput: (input, run) => {
    const base = (input as { base?: string | null })?.base ?? run.baseSha;
    return { target: `base:${base}`, smoke: false };
  },
};

const simplify: SubflowBlockDefinition = {
  name: "simplify",
  kind: "subflow",
  purpose: "Cross-model simplify pass over the run diff, preserving behavior (R2).",
  inputSchema: z.object({ base: z.string().nullish() }),
  outputSchema: z.object({ status: z.string() }).loose(),
  inputSchemaId: HANDOFF_IN,
  outputSchemaId: HANDOFF_OUT,
  external: false,
  needsWorkspace: true,
  scan: false,
  preconditions: [],
  waivePolicies: ["none", "approval"],
  defaults: { retries: 0, timeoutMs: 30 * 60_000 },
  costProfile: { estUsd: 10 },
  gateFn: (recorded) => {
    const status = (recorded as { status?: string })?.status;
    if (status === undefined) return red("simplify produced no status — an absent envelope is not a pass");
    return status === "degraded" ? red("simplify degraded — needs a human") : green;
  },
  mirrorKey: "simplify",
  buildSubflowInput: (input, run) => ({
    repoPath: run.worktreePath,
    baseSha: (input as { base?: string | null })?.base ?? run.baseSha,
    validateCmd: run.validateCmd,
    validateTimeoutMs: run.validateTimeoutMs,
    smoke: false,
  }),
};

const docReview: SubflowBlockDefinition = {
  name: "doc-review",
  kind: "subflow",
  purpose: "Multi-leg plan/spec review (external legs); no workspace required (R2).",
  inputSchema: z.object({ planPath: z.string() }),
  outputSchema: z.object({ claudeStatus: z.string().nullish(), opencodeStatus: z.string().nullish() }).loose(),
  inputSchemaId: HANDOFF_IN,
  outputSchemaId: HANDOFF_OUT,
  external: true,
  needsWorkspace: false,
  scan: false,
  preconditions: ["a secret-scan ancestor (validator-enforced)"],
  waivePolicies: ["none", "approval"],
  defaults: { retries: 1, timeoutMs: 25 * 60_000 },
  costProfile: { estUsd: 6 },
  gateFn: (recorded) => {
    const out = recorded as { claudeStatus?: string; opencodeStatus?: string };
    return out?.claudeStatus === "ok" || out?.opencodeStatus === "ok" ? green : red("both doc-review legs unavailable — not a silent pass");
  },
  externalContract: EXTERNAL_CONTRACT,
  mirrorKey: "docReview",
  buildSubflowInput: (input) => ({ docPath: (input as { planPath: string }).planPath, smoke: false }),
};

export const INITIAL_LIBRARY: readonly (AgentBlockDefinition | ComputeBlockDefinition | SubflowBlockDefinition)[] = [
  secretScan,
  rescan,
  commitWork,
  runValidate,
  proofArtifacts,
  pr,
  work,
  repro,
  analysis,
  subtasks,
  codeReview,
  simplify,
  docReview,
];

// The composable registry the CLI catalog and the interpreter share. Every block
// speaks the shared handoff schema, so a single self-adapter lets any producer
// feed any consumer at compose time; runtime parse with each block's own zod
// schema is the real type gate at dispatch (KTD14).
export function buildRegistry(): BlockRegistry {
  const registry = new BlockRegistry();
  for (const block of INITIAL_LIBRARY) registry.register(block);
  registry.declareAdapter(HANDOFF_OUT, HANDOFF_IN);
  return registry;
}
