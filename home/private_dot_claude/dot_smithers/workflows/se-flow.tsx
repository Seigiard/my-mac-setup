/** @jsxImportSource smithers-orchestrator */
// se-flow: the ONE static interpreter workflow (KTD1/R5/R7). Its statically
// imported module graph never changes between runs — only the spec passed as
// input varies — so Smithers' workflowHash (computed over the module graph's
// file contents, not the rendered tree) is stable and resume works for any
// composed flow. The composable block list is spec-driven; the fixed prolog
// (lock + worktree staging + provenance) and epilog (outcome record + terminal
// reviewer + cleanup) are interpreter-owned and run on every flow (KTD2).
//
// Zero-in-flight rule (KTD1): every file in this module graph — this file, the
// block library, and the shared libs — is edited only when no run is live or
// parked; otherwise runs are drained first. Editing an imported file under a
// live run reproduces Smithers issue #1493 (RESUME_METADATA_MISMATCH).
//
// Launch (the `se flow` CLI wraps this):
//   cd ~/.claude/.smithers && FLOW_REPO=/abs/repo \
//     ./node_modules/.bin/smithers up workflows/se-flow.tsx \
//     --input '{"specPath":"/abs/spec.json","budgetUsd":25,"setupCmd":""}'
//
// Verification status: this render is structurally complete and its module
// graph resolves, but its live execution (worktree provisioning, block
// dispatch, PR open, kill/resume hash-stability) is exercised by the plan's
// live fixture flow, which requires a running Smithers daemon and is not run in
// a headless build.
import { createSmithers, Subflow, TryCatchFinally, approvalDecisionSchema, type ProofBinding } from "smithers-orchestrator";
import type { WorkflowDefinition } from "@smithers-orchestrator/driver";
import { z } from "zod/v4";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { validateFlowSpec } from "./lib/flow-validate.ts";
import { buildRegistry } from "./lib/blocks/index.ts";
import { runComputeEffect, type ComputeEffectContext } from "./lib/block-effects.ts";
import {
  blockNodeId,
  canonicalSpecJson,
  dispatchableBlocks,
  dispatchNodeId,
  epilogShouldRender,
  flowVerdict,
  formatPrBody,
  frozenPlanNote,
  needsWorkspace,
  planBearingAgentBlocks,
  specHash,
  topoOrder,
  withheldByBlock,
  withStagedPlanPath,
  type FlowDispatch,
  type GateApprovalDecision,
  type RecordedBlock,
} from "./lib/flow-run.ts";
import type { FlowBlock, FlowSpec } from "./lib/flow-spec.ts";
import { blockLogExcerpts, buildIssueFields, buildReviewerPrompt, classifyDisposition, parseReviewerVerdict, type BlockOutcome, type OutcomeRecord, type ReviewerVerdict } from "./lib/reviewer.ts";
import { redactSecretsInText, shouldWriteIssue, writeIssueFile } from "./lib/issue-writer.ts";
import { copyArtifacts, inboundPromptNote, parseArchiveManifest, planArtifactArchive, planInboundDelivery, type BlockPayload } from "./lib/archive.ts";
import { agentCapUsd, aggregateUsage, evaluateBudget, openUsageDb, readRunUsage } from "./lib/cost.ts";
import { makeFlowReviewerAgent } from "./lib/agents.ts";
import type { SubflowRunContext } from "./lib/block-registry.ts";
import seCodeReview from "./se-code-review.tsx";
import seDocReview from "./se-doc-review.tsx";
import seSimplify from "./se-simplify.tsx";
import {
  acquireRepoLock,
  cleanupSnapshot,
  git,
  releaseRepoLock,
  resolveStagedPlans,
  runBranchName,
  stageRunPlan,
  stageRunWorktree,
  sweepOrphans,
  type GetRunState,
  type PlanResolution,
  type StagedPlan,
} from "./lib/staging.ts";
import { planContentHash } from "./lib/gates.ts";

const inputSchema = z.object({
  specPath: z.string().describe("Absolute path to the validated flow-spec JSON (read from the launcher, never the worktree — KTD11)."),
  budgetUsd: z.number().nullish().describe("Run cost ceiling; a breach PARKS the run for an operator ack, never hard-kills (KTD9)."),
  setupCmd: z.string().default("").describe("Operator-supplied worktree provisioning command (KTD15-trusted). Empty = no setup."),
  validateCmd: z.string().default("").describe("Operator-supplied behavior check the run-validate block and the simplify subflow execute. Command-bearing input arrives here, never in the spec (KTD15)."),
  validateTimeoutMs: z.number().default(10 * 60_000).describe("Hang guard for validateCmd."),
});

// Subflow blocks wrap existing workflows. The map is fixed in this file so the
// module graph is identical across runs (R7); a block naming a workflow that is
// not here records a red row rather than silently skipping.
const SUBFLOW_WORKFLOWS: Record<string, WorkflowDefinition<unknown>> = {
  "code-review": seCodeReview as unknown as WorkflowDefinition<unknown>,
  "doc-review": seDocReview as unknown as WorkflowDefinition<unknown>,
  simplify: seSimplify as unknown as WorkflowDefinition<unknown>,
};

interface CtxLike {
  prove: (o: unknown, opts: { nodeId: string }) => ProofBinding | undefined;
  outputMaybe: (key: string, opts: { nodeId: string }) => Record<string, unknown> | undefined;
}

// KTD3: one generic block-output table plus a closed mirror-key set. A subflow
// block writes its own shape into its mirror key; the interpreter copies that
// row into blockOutput. The mirror set is CLOSED (simplify, docReview,
// reviewLeg) so this workflow file stays identical across runs (R7).
const blockOutputSchema = z.object({
  blockId: z.string(),
  kind: z.enum(["agent", "compute", "subflow"]),
  status: z.enum(["green", "failed", "degraded", "stopped", "non-terminal"]),
  payloadJson: z.string(),
});

const { Workflow, Task, Sequence, Approval, smithers, outputs } = createSmithers({
  input: inputSchema,
  // Fixed prolog/epilog keys.
  gate0: z.object({ specHash: z.string(), repoPath: z.string(), needsWorkspace: z.boolean(), budgetUsd: z.number().nullish() }),
  // `plans` are the frozen plan copies handed to agent blocks instead of the
  // launcher's paths (docs/issues/2026-08-15-002). `.nullish()` for the same
  // reason as `outcome.verdict`: a run persisted before this field existed is
  // read back through this schema on resume, and a required field would refuse
  // it — such a run simply has no copy and keeps the operator's path.
  staging: z.object({
    worktreePath: z.string(),
    branch: z.string(),
    baseSha: z.string(),
    plans: z.array(z.object({ blockId: z.string(), planPath: z.string(), planHash: z.string(), copyPath: z.string() })).nullish(),
  }),
  setup: z.object({ exitCode: z.number() }),
  budget: z.object({ spentUsd: z.number(), breached: z.boolean() }),
  approval: approvalDecisionSchema,
  // R9: what a prior run's archive actually handed over. `skipped` is kept so a
  // handoff that silently delivered nothing is visible in the run.
  inbound: z.object({ source: z.string(), delivered: z.array(z.object({ name: z.string(), path: z.string() })), skipped: z.array(z.string()) }),
  // flowRunId, not runId: smithers reserves runId/nodeId/iteration as internal
  // columns on every persisted node output and refuses a schema that shadows
  // them. The engine raises this at workflow construction, which `bun build`
  // cannot see — it type-checks nothing and never instantiates the workflow.
  // `verdict`/`stoppedBy` are `.nullish()` because a run persisted before they
  // existed still has to resume: the engine reads the old row back through this
  // schema, and a required field would refuse it.
  outcome: z.object({
    flowRunId: z.string(),
    recordPath: z.string(),
    archiveDir: z.string(),
    artifactCount: z.number(),
    redactionHits: z.array(z.string()),
    verdict: z.string().nullish(),
    stoppedBy: z.string().nullish(),
  }),
  reviewerVerdict: z.object({ actionableOptimization: z.boolean(), summary: z.string(), cause: z.string().nullish(), proposedFix: z.string().nullish() }),
  // R15: `issuePath` is null on a clean success — the review lives in the
  // outcome record and no file is written. `redactionHits` surfaces a KTD13
  // catch, so a redacted secret is visible in the run rather than only in the file.
  issue: z.object({ disposition: z.string(), issuePath: z.string().nullish(), redactionHits: z.array(z.string()) }),
  // Generic per-block output.
  blockOutput: blockOutputSchema,
  // One fixed key for every agent block's raw envelope, namespaced per node by
  // the engine. Fixed, not per-block, so the workflow file stays identical
  // across runs (R7); the block's gateFn classifies the row into blockOutput.
  agentReport: z.object({ report: z.string() }),
  // Closed mirror-key set (KTD3).
  simplify: z.object({ status: z.string() }).loose(),
  docReview: z.object({ claudeStatus: z.string().nullish(), opencodeStatus: z.string().nullish() }).loose(),
  reviewLeg: z.object({ status: z.string() }).loose(),
});

function readSpec(specPath: string): FlowSpec {
  const raw = JSON.parse(fs.readFileSync(specPath, "utf8")) as unknown;
  const registry = buildRegistry();
  const result = validateFlowSpec(raw, { registry: registry.view(), archiveExists: (id) => fs.existsSync(id) });
  if (!result.ok) {
    throw new Error(`gate-0 refused: spec is invalid — ${JSON.stringify(result.errors)}`);
  }
  return result.spec;
}

export default smithers((ctx) => {
  const input = ctx.input;
  const runId = ctx.runId ?? `run-${Date.now()}`;
  const repoPath = process.env.FLOW_REPO ?? "";
  const setupCmd = (input.setupCmd ?? "").trim();

  const spec = readSpec(input.specPath);
  const registry = buildRegistry();
  const workspaceNeeded = needsWorkspace(spec, (name) => registry.get(name)?.needsWorkspace ?? false);
  const ordered = topoOrder(spec.blocks);
  // Computed once, before anything reads it: the block loop dispatches from it,
  // the epilog's outcome record takes its verdict from it, and blockOutcomes
  // marks the withheld blocks from it. Pure over the recorded rows, so calling
  // it here costs nothing and every consumer sees the same decision.
  const dispatch = flowDispatch(ctx, ordered);

  const gate0 = ctx.outputMaybe("gate0", { nodeId: "gate0" });
  const staged = ctx.outputMaybe("staging", { nodeId: "staging" });
  // Same presence-not-value rule as the block binds below: spread the prop so a
  // missing gate0 row cannot arm verification with nothing to verify.
  const gate0Proof = ctx.prove(outputs.gate0, { nodeId: "gate0" });
  const gate0BindProps = gate0Proof === undefined ? {} : { bind: gate0Proof };

  const children: unknown[] = [
    // Fixed prolog: spec provenance (gate0 role). Refuses launch on an invalid
    // spec (readSpec throws) so no worktree is ever staged for a bad flow.
    <Task id="gate0" output={outputs.gate0} retries={0}>
      {() => ({ specHash: specHash(spec), repoPath, needsWorkspace: workspaceNeeded, budgetUsd: input.budgetUsd ?? null })}
    </Task>,
  ];

  // Conditional prolog (KTD2): a workspace-free flow acquires no lock and stages
  // no worktree. The conditionality is computed here, never spec-expressible.
  if (workspaceNeeded && gate0) {
    children.push(
      <Task id="staging" output={outputs.staging} retries={0} {...gate0BindProps}>
        {() => {
          const getState: GetRunState = () => undefined;
          const branch = runBranchName(spec.task.description, runId);
          // Plans are frozen BEFORE the lock is taken: an unreadable plan path
          // is an operator error that must refuse the launch, and refusing it
          // here leaves no lock and no worktree behind to clean up by hand.
          // The hash is taken now and persisted — se-flow has no gate 0, so
          // this staging moment IS the run's freeze point (KTD7's intent: the
          // run executes the spec it gated, and a copy cannot be edited
          // mid-run at all).
          const plans: StagedPlan[] = planBearingAgentBlocks(ordered, (name) => registry.get(name)?.kind === "agent").map((entry) => {
            const planHash = planContentHash(fs.readFileSync(entry.planPath, "utf8"));
            return { ...entry, planHash, copyPath: stageRunPlan(entry.planPath, branch, planHash) };
          });
          acquireRepoLock(repoPath, runId, getState);
          sweepOrphans(repoPath, getState);
          const st = stageRunWorktree(repoPath, branch, git(repoPath, "rev-parse", "HEAD"));
          return { worktreePath: st.worktreePath, branch: st.branch, baseSha: st.baseSha, plans };
        }}
      </Task>,
    );
    if (staged && setupCmd) {
      children.push(
        <Task id="setup" output={outputs.setup} retries={0}>
          {() => ({ exitCode: 0 })}
        </Task>,
      );
    }
    // R9/AE4: a prior run's artifacts are copied into this worktree before any
    // block runs, so a block that needs them finds them on disk rather than
    // being told an archive exists somewhere.
    if (staged && spec.artifactsFrom) {
      children.push(renderInboundDelivery(spec.artifactsFrom, staged.worktreePath));
    }
  }

  // Spec-driven block loop. Each block renders under a deterministic `b:<id>`
  // node id (KTD1); bind proofs come from the block's bindTo edges (KTD12); the
  // block's registered zod schema runtime-parses its input at dispatch (KTD14).
  const worktreePath = staged?.worktreePath ?? repoPath;
  // Re-verified on every render, not read straight out of the row: the copy has
  // to still exist and still match the plan the run froze when the prompt that
  // names it is built. With no staged worktree (worktreePath === repoPath) there
  // is nothing here — no isolation to protect, and the prompt keeps the
  // operator's own path.
  //
  // Never after cleanup: re-staging then would write the plan's full text back
  // into /tmp moments after the epilog deleted it, and leave it there for good.
  // No block can dispatch after cleanup anyway — it is the last epilog node.
  const cleanedUp = ctx.outputMaybe("setup", { nodeId: "cleanup" }) !== undefined;
  const stagedPlans: Record<string, PlanResolution> = cleanedUp
    ? {}
    : resolveStagedPlans((staged?.plans as StagedPlan[] | undefined) ?? [], (staged?.branch as string | undefined) ?? "");
  const effectCtx: ComputeEffectContext = {
    worktreePath,
    baseSha: staged?.baseSha ?? "",
    branch: staged?.branch ?? "",
    runId,
    validateCmd: (input.validateCmd ?? "").trim(),
    validateTimeoutMs: input.validateTimeoutMs,
    // R11: composed here so the `pr` block publishes the spec and the run's
    // status, not a bare run id. prEffect redacts it again at the push
    // boundary — composing and publishing are different moments, and only the
    // second one is irreversible.
    prBody: formatPrBody(runId, canonicalSpecJson(spec), blockOutcomes(ctx, ordered)),
  };
  const subflowRun = {
    worktreePath,
    baseSha: staged?.baseSha ?? "",
    branch: staged?.branch ?? "",
    validateCmd: (input.validateCmd ?? "").trim(),
    validateTimeoutMs: input.validateTimeoutMs,
  };
  // Blocks wait for the handoff: dispatching an agent before its evidence
  // landed would spend a leg on a worktree that is missing the very files the
  // spec asked to hand over.
  const inboundPending = workspaceNeeded && spec.artifactsFrom !== null && ctx.outputMaybe("inbound", { nodeId: INBOUND_NODE }) === undefined;
  const inboundNote = inboundPromptNote(deliveredInbound(ctx));
  const readyGate = (workspaceNeeded ? staged : gate0) && !inboundPending;
  if (readyGate) {
    // KTD9: spend is measured after every block, and a breach PARKS the run for
    // an operator ack instead of killing it. One ack per run: a second Approval
    // node would reuse the same id, and asking again after every later block
    // turns a ceiling into a nag.
    const budgetApproved = ctx.outputMaybe("approval", { nodeId: BUDGET_APPROVAL_NODE })?.approved === true;
    let approvalRendered = false;
    const gateApprovals = new Set(dispatch.gateApprovals);
    for (const { block, bindNodeIds } of dispatch.dispatchable) {
      children.push(renderBlock(ctx, block, registry, effectCtx, subflowRun, bindNodeIds, inboundNote, stagedPlans[block.id]));
      children.push(renderBudgetTask(block.id, runId, input.budgetUsd));
      // Rendered right after its own block, so the pause sits between the red
      // gate and everything the gate is holding back. dispatchableBlocks already
      // withheld those successors; this node is where the operator releases them.
      if (gateApprovals.has(block.id)) {
        children.push(renderGateApproval(ctx, block, dispatch));
      }
      const breached = ctx.outputMaybe("budget", { nodeId: budgetNodeId(block.id) })?.breached === true;
      if (breached && !approvalRendered) {
        approvalRendered = true;
        children.push(renderBudgetApproval(ctx, block.id, input.budgetUsd));
        if (!budgetApproved) break;
      }
    }
  }

  // Fixed epilog on every exit path (KTD2/KTD10): outcome record + artifact
  // archive, terminal reviewer slot (U6, cannot block cleanup), cleanup + lock
  // release. Timeout-bounded; the reviewer reads only the durable record.
  //
  // A run stopped by a red gate reaches this too: withholding leaves blocks
  // unrecorded, but it only ever happens because a block recorded a red row, and
  // epilogShouldRender's second arm is exactly that. Trading a published-after-red
  // PR for a run with no outcome record would be the worse bug.
  if (readyGate && epilogShouldRender(ordered, (id) => recordedBlock(ctx as CtxLike, id))) {
    children.push(renderEpilog(ctx, spec, ordered, worktreePath, repoPath, workspaceNeeded, runId));
  }

  return (
    <Workflow name="se-flow">
      <Sequence>{children}</Sequence>
    </Workflow>
  );
});

const BUDGET_APPROVAL_NODE = "approve-budget";
const INBOUND_NODE = "inbound-artifacts";

// R9/AE4: copy a prior run's published artifacts into this run's worktree. The
// spec names the archive; the validator has already confirmed it exists, so a
// missing record here is a real failure rather than a bad spec.
function renderInboundDelivery(artifactsFrom: string, worktreePath: string): unknown {
  return (
    <Task id={INBOUND_NODE} output={outputs.inbound} retries={0}>
      {() => {
        const recordPath = artifactsFrom.endsWith(".json") ? artifactsFrom : path.join(artifactsFrom, "outcome.json");
        if (!fs.existsSync(recordPath)) {
          throw new Error(`artifactsFrom "${artifactsFrom}" has no outcome record at ${recordPath} — the archive exists but publishes nothing (KTD10)`);
        }
        const result = copyArtifacts(planInboundDelivery(parseArchiveManifest(fs.readFileSync(recordPath, "utf8")), worktreePath));
        return {
          source: recordPath,
          delivered: result.copied.map((e) => ({ name: e.name, path: e.destination })),
          skipped: result.skipped.map((s) => `${s.path}: ${s.reason}`),
        };
      }}
    </Task>
  );
}

function deliveredInbound(ctx: unknown): { blockId: string; name: string; source: string; destination: string }[] {
  const row = (ctx as CtxLike).outputMaybe("inbound", { nodeId: INBOUND_NODE });
  const delivered = (row?.delivered ?? []) as Array<{ name: string; path: string }>;
  return delivered.map((d) => ({ blockId: "inbound", name: d.name, source: d.path, destination: d.path }));
}

function budgetNodeId(blockId: string): string {
  return `budget:${blockId}`;
}

function measureSpend(runId: string): number {
  return aggregateUsage(readRunUsage(runId, process.cwd(), openUsageDb)).totalEstUsd;
}

// Measured after each block rather than once at the end: a ceiling checked only
// in the epilog reports an overspend that already happened.
function renderBudgetTask(blockId: string, runId: string, ceilingUsd: number | null | undefined): unknown {
  return (
    <Task id={budgetNodeId(blockId)} output={outputs.budget} retries={0}>
      {() => evaluateBudget(measureSpend(runId), ceilingUsd)}
    </Task>
  );
}

// onDeny "fail" matches the pipeline's gates: denying a budget breach stops the
// run. The epilog still runs, because it renders on the failure path too.
function renderBudgetApproval(ctx: unknown, blockId: string, ceilingUsd: number | null | undefined): unknown {
  const spent = (ctx as CtxLike).outputMaybe("budget", { nodeId: budgetNodeId(blockId) })?.spentUsd;
  const spentText = typeof spent === "number" ? `$${spent.toFixed(2)}` : "an unknown amount";
  return (
    <Approval
      id={BUDGET_APPROVAL_NODE}
      output={outputs.approval}
      request={{
        title: `Budget ceiling passed after block "${blockId}" — approve to continue spending, deny to stop the run`,
        summary: [
          `Estimated spend so far: ${spentText}. Ceiling: $${ceilingUsd ?? 0}.`,
          "Tokens are the authoritative metric; the dollar figure is an estimate (KTD6).",
          "Approving acks the whole run, not just this block — the ceiling is not asked about again.",
        ].join(" "),
      }}
      onDeny="fail"
    />
  );
}

// A block's durable verdict lives under its own node id, or — when its task
// threw and the guard caught — under the guard's crash node. Both rows are the
// block's verdict, so every reader accepts either: bind resolution, epilog
// readiness, and the outcome record. Reading only the plain node id would leave
// a crashed block looking un-run forever, and the epilog would never render.
function blockRowNodeId(ctx: CtxLike, blockId: string): string | undefined {
  const nodeId = blockNodeId(blockId);
  if (ctx.outputMaybe("blockOutput", { nodeId }) !== undefined) return nodeId;
  const crashedNodeId = `${nodeId}-crashed`;
  return ctx.outputMaybe("blockOutput", { nodeId: crashedNodeId }) !== undefined ? crashedNodeId : undefined;
}

function blockRow(ctx: CtxLike, blockId: string): Record<string, unknown> | undefined {
  const nodeId = blockRowNodeId(ctx, blockId);
  return nodeId === undefined ? undefined : ctx.outputMaybe("blockOutput", { nodeId });
}

// The settled verdict dispatchableBlocks keys its stop-on-red decision on: the
// node the row landed under, plus its `status`. Presence of the row is the proof
// that the block's retries are spent — Smithers persists an output row only on
// the attempt that RETURNS, and a red gate returns rather than throwing, so no
// earlier red row can exist for a block a retry later turned green. A block that
// threw every attempt has no row here at all; its verdict is the guard's
// `-crashed` row, which blockRowNodeId already resolves and which is red.
//
// A row with a non-string status is read as `non-terminal`, never as green: an
// unreadable verdict is missing evidence (the same rule salvage.ts applies).
function recordedBlock(ctx: CtxLike, blockId: string): RecordedBlock | undefined {
  const nodeId = blockRowNodeId(ctx, blockId);
  if (nodeId === undefined) return undefined;
  const status = ctx.outputMaybe("blockOutput", { nodeId })?.status;
  return { nodeId, status: typeof status === "string" ? status : "non-terminal" };
}

// Per-block, never per-run: the budget ack is deliberately one node for the
// whole run, but a gate waive is a decision about ONE block's red verdict, so
// each red block gets its own approval row. Sharing an id would let an ack for
// one block silently waive another. `approve-` is a reserved spec-id prefix
// (flow-spec RESERVED_ID_PREFIXES) and block ids are unique, so no spec can
// collide with these node ids and no two blocks can collide with each other.
function gateApprovalNodeId(blockId: string): string {
  return `approve-waive-${blockId}`;
}

function gateApprovalDecision(ctx: CtxLike, blockId: string): GateApprovalDecision {
  const row = ctx.outputMaybe("approval", { nodeId: gateApprovalNodeId(blockId) });
  if (row === undefined) return "pending";
  return row.approved === true ? "approved" : "denied";
}

function flowDispatch(ctx: unknown, ordered: FlowBlock[]): FlowDispatch {
  const c = ctx as CtxLike;
  return dispatchableBlocks(ordered, (id) => recordedBlock(c, id), (id) => gateApprovalDecision(c, id));
}

// The `waive: "approval"` half of the WAIVE_POLICIES contract (flow-spec.ts): a
// red gate on a block the composer marked risky parks the run here instead of
// stopping it. Same shape as the budget pause and the same onDeny "fail" — the
// pipeline's gates all read that way, and denying stops the run while the epilog
// still renders, because the epilog renders on the failure path too.
function renderGateApproval(ctx: unknown, block: FlowBlock, dispatch: FlowDispatch): unknown {
  const status = recordedBlock(ctx as CtxLike, block.id)?.status ?? "red";
  const held = withheldByBlock(dispatch, block.id);
  return (
    <Approval
      id={gateApprovalNodeId(block.id)}
      output={outputs.approval}
      request={{
        title: `Block "${block.id}" (${block.block}) gated ${status} — approve to waive this gate and continue, deny to stop the run`,
        summary: [
          `The block declared waive: "approval", so a red gate parks here instead of stopping its successors outright.`,
          held.length > 0 ? `Withheld until you decide: ${held.join(", ")}.` : "No block depends on it, so nothing downstream is waiting.",
          "Approving waives only THIS block's gate; every other block keeps its own policy.",
        ].join(" "),
      }}
      onDeny="fail"
    />
  );
}

// A block becomes an engine node keyed to its kind. Compute effect bodies reuse
// the shared lib functions; agent blocks dispatch through the registered
// makeAgent + buildPrompt (KTD3); subflow blocks write a mirror key the
// interpreter copies into blockOutput.
function renderBlock(
  ctx: unknown,
  block: FlowBlock,
  registry: ReturnType<typeof buildRegistry>,
  effectCtx: ComputeEffectContext,
  subflowRun: SubflowRunContext,
  bindNodeIds: string[],
  inboundNote: string,
  planResolution: PlanResolution | undefined,
): unknown {
  const def = registry.get(block.block);
  const nodeId = blockNodeId(block.id);
  const proofs = bindNodeIds.map((target) => (ctx as CtxLike).prove(outputs.blockOutput, { nodeId: target }));
  const bindings = proofs.filter((proof): proof is ProofBinding => proof !== undefined);
  // Spread, never `bind={...}` with a possibly-undefined value: the engine arms
  // proof verification on the PROP'S PRESENCE, not its value — graph/extract.js
  // tests `Object.hasOwn(raw, "bind")`. So `bind={undefined}` arms verification
  // with zero proofs, and the node parks as waiting-bound while the whole run
  // parks as waiting-event, with an empty error and no way to resume. A block
  // with no bindTo edges must not carry the prop at all.
  const bindProps = bindings.length > 0 ? { bind: bindings } : {};

  // Runtime-parse the block's declared input (KTD14) — enforces
  // .refine()/.transform()/.nullish() semantics JSON Schema cannot express.
  // A block that cannot be dispatched records a red row instead of running:
  // an agent leg is too expensive to spend on input the registry already
  // refused, and a silent skip would let the epilog read a missing block.
  const parsedInput = def ? def.inputSchema.safeParse(block.input) : { success: false as const };
  // A plan that no longer matches what the run froze is refused the same way:
  // red row, no dispatch. The alternative — running the block against the
  // operator's live plan — is the escape this whole path exists to close.
  const planRefusal = planResolution !== undefined && !planResolution.ok ? planResolution.reason : undefined;
  if (!def || !parsedInput.success || bindings.length !== proofs.length || planRefusal !== undefined) {
    // A dropped proof is red, never a silent unbound dispatch: dispatchableBlocks
    // withholds a block until every bindTo row exists, so a proof missing HERE
    // means the authority row disappeared between that check and this render.
    // Running the block anyway would spend it against data nothing vouches for.
    const reason = !def
      ? `block "${block.block}" is not in the registry`
      : !parsedInput.success
        ? `block "${block.id}" input failed runtime parse (KTD14)`
        : planRefusal !== undefined
          ? `block "${block.id}" cannot use its frozen plan copy: ${planRefusal}`
          : `block "${block.id}" lost a bind-proof row between readiness and dispatch (KTD12)`;
    return (
      <Task id={nodeId} output={outputs.blockOutput} retries={0}>
        {() => ({ blockId: block.id, kind: def?.kind ?? "compute", status: "failed" as const, payloadJson: JSON.stringify({ reason }) })}
      </Task>
    );
  }

  const crashed = (
    <Task id={`${nodeId}-crashed`} output={outputs.blockOutput} retries={0}>
      {() => ({ blockId: block.id, kind: def.kind, status: "non-terminal" as const, payloadJson: "{}" })}
    </Task>
  );

  // Agent blocks: the engine dispatches the registered agent, then a
  // deterministic task classifies its recorded envelope. Two nodes rather than
  // one because an agent Task's child is a prompt, not a closure — the gateFn
  // has to run somewhere that can read the persisted row.
  if (def.kind === "agent") {
    const agentNodeId = dispatchNodeId(nodeId);
    const reported = (ctx as CtxLike).outputMaybe("agentReport", { nodeId: agentNodeId }) !== undefined;
    // THE substitution seam (docs/issues/2026-08-15-002): buildPrompt is pure
    // over the block's input, so the launcher path is swapped for the frozen
    // copy here — the only layer that knows both. Nothing downstream ever sees
    // the operator's path, and the note tells the agent what the file it is
    // reading actually is.
    const promptInput = planResolution?.ok ? withStagedPlanPath(parsedInput.data, planResolution.copyPath) : parsedInput.data;
    const planNote = planResolution?.ok ? frozenPlanNote(planResolution.copyPath) : "";
    return (
      <TryCatchFinally
        id={`guard-${block.id}`}
        try={
          <Sequence>
            <Task
              id={agentNodeId}
              output={outputs.agentReport}
              agent={def.makeAgent({ worktreePath: effectCtx.worktreePath, timeoutMs: block.timeoutMs, budgetUsd: agentCapUsd(def.costProfile.estUsd) })}
              retries={block.retries}
              {...bindProps}
            >
              {`${def.buildPrompt(promptInput)}${planNote}${inboundNote}`}
            </Task>
            {reported ? classifyTask(ctx, block, def, nodeId, agentNodeId) : null}
          </Sequence>
        }
        catch={crashed}
      />
    );
  }

  // Subflow blocks run an existing workflow, which writes its own shape into
  // the block's mirror key; a follow-up task copies that row into the generic
  // blockOutput (KTD3). Same two-node split as agents, same reason.
  if (def.kind === "subflow") {
    const workflow = SUBFLOW_WORKFLOWS[def.name];
    if (!workflow) {
      return (
        <Task id={nodeId} output={outputs.blockOutput} retries={0}>
          {() => ({ blockId: block.id, kind: "subflow" as const, status: "failed" as const, payloadJson: JSON.stringify({ reason: `no workflow wired for subflow block "${def.name}"` }) })}
        </Task>
      );
    }
    const subNodeId = dispatchNodeId(nodeId);
    const mirrored = (ctx as CtxLike).outputMaybe(def.mirrorKey, { nodeId: subNodeId }) !== undefined;
    return (
      <TryCatchFinally
        id={`guard-${block.id}`}
        try={
          <Sequence>
            <Subflow
              id={subNodeId}
              workflow={workflow}
              input={def.buildSubflowInput(parsedInput.data, subflowRun)}
              output={mirrorOutput(def.mirrorKey)}
              retries={block.retries}
              timeoutMs={block.timeoutMs}
            />
            {mirrored ? mirrorCopyTask(ctx, block, def, nodeId, subNodeId) : null}
          </Sequence>
        }
        catch={crashed}
      />
    );
  }

  // Compute blocks run their effect body against the staged worktree and
  // classify in one node — the effect is a plain synchronous function.
  return (
    <TryCatchFinally
      id={`guard-${block.id}`}
      try={
        <Task id={nodeId} output={outputs.blockOutput} retries={block.retries} {...bindProps}>
          {() => {
            const payload = runComputeEffect(def.name, parsedInput.data, { ...effectCtx, validateTimeoutMs: block.timeoutMs });
            const gate = def.gateFn(payload);
            return {
              blockId: block.id,
              kind: def.kind,
              status: gate.state === "green" ? ("green" as const) : ("failed" as const),
              payloadJson: JSON.stringify(payload),
            };
          }}
        </Task>
      }
      catch={crashed}
    />
  );
}

// Resolves a mirror key to its declared output. The set is closed (KTD3), so an
// unknown key is a programming error in this file, not spec-reachable.
function mirrorOutput(mirrorKey: string): unknown {
  switch (mirrorKey) {
    case "simplify":
      return outputs.simplify;
    case "docReview":
      return outputs.docReview;
    case "reviewLeg":
      return outputs.reviewLeg;
    default:
      throw new Error(`mirror key "${mirrorKey}" is outside the closed set (KTD3)`);
  }
}

// Copies a subflow's mirror row into the generic blockOutput and classifies it.
// A missing row is red for the same reason a missing agent envelope is: the
// subflow did not report, which is not evidence that it succeeded.
function mirrorCopyTask(ctx: unknown, block: FlowBlock, def: { mirrorKey: string; gateFn: (r: unknown) => { state: string } }, nodeId: string, subNodeId: string): unknown {
  return (
    <Task id={nodeId} output={outputs.blockOutput} retries={0}>
      {() => {
        const recorded = (ctx as CtxLike).outputMaybe(def.mirrorKey, { nodeId: subNodeId });
        const gate = def.gateFn(recorded);
        return {
          blockId: block.id,
          kind: "subflow" as const,
          status: gate.state === "green" ? ("green" as const) : ("failed" as const),
          payloadJson: JSON.stringify(recorded ?? { reason: "subflow produced no mirror row" }),
        };
      }}
    </Task>
  );
}

// Classifies an agent block's recorded envelope into the generic blockOutput
// row. A missing row is red, never green: the agent leg died without reporting,
// and an absent envelope is not evidence of success (R7).
function classifyTask(ctx: unknown, block: FlowBlock, def: { kind: string; gateFn: (r: unknown) => { state: string } }, nodeId: string, agentNodeId: string): unknown {
  return (
    <Task id={nodeId} output={outputs.blockOutput} retries={0}>
      {() => {
        const recorded = (ctx as CtxLike).outputMaybe("agentReport", { nodeId: agentNodeId });
        const gate = def.gateFn(recorded ?? {});
        return {
          blockId: block.id,
          kind: def.kind as "agent",
          status: gate.state === "green" ? ("green" as const) : ("failed" as const),
          payloadJson: JSON.stringify(recorded ?? { reason: "agent produced no envelope" }),
        };
      }}
    </Task>
  );
}

// A block with no row is `stopped` when a red ancestor withheld it and
// `non-terminal` otherwise. The distinction is the point: `non-terminal` means a
// leg died without reporting, and telling the terminal reviewer that about five
// blocks that were never dispatched would send it chasing failures that never
// happened. Both are still failure evidence to reviewer.ts — neither is green.
function blockOutcomes(ctx: unknown, ordered: FlowBlock[]): BlockOutcome[] {
  const withheld = new Set(flowDispatch(ctx, ordered).withheld);
  return ordered.map((b) => {
    const out = blockRow(ctx as CtxLike, b.id);
    const fallback: BlockOutcome["status"] = withheld.has(b.id) ? "stopped" : "non-terminal";
    return { blockId: b.id, block: b.block, status: (out?.status as BlockOutcome["status"]) ?? fallback };
  });
}

const REVIEWER_TIMEOUT_MS = 15 * 60_000;

// Terminal reviewer (R14/R15/U6): an agent leg reads the recorded block rows and
// returns a cause analysis or an optimization finding, then a deterministic task
// turns that verdict into a docs/issues/ file — on failure or an actionable
// optimization only; a clean success lives in the outcome record (R15).
//
// The agent never writes the file. It returns prose, and `writeIssueFile`
// redacts and writes it, so KTD13's publication-time scan is enforced by code
// rather than trusted to a model that was just handed untrusted log text.
//
// The guard is what lets the reviewer be a slot that "cannot block cleanup"
// (KTD2): the epilog is a Sequence, so an unguarded agent failure would abort it
// and leak both the worktree and the repo lock. On a crash the catch records a
// no-verdict row and the sequence continues.
//
// Issue writing sits OUTSIDE the guard on purpose. Inside the try branch it
// would be skipped whenever the reviewer leg died — and a run whose reviewer
// died is exactly a run that owes the operator an issue file (R15). Outside, it
// runs off whichever verdict row exists, the parsed one or the crash fallback.
function renderReviewer(ctx: unknown, ordered: FlowBlock[], worktreePath: string, runId: string): unknown {
  const c = ctx as CtxLike;
  const record = reviewerRecord(ctx, ordered, runId);
  const reported = c.outputMaybe("agentReport", { nodeId: REVIEWER_DISPATCH_NODE }) !== undefined;

  return (
    <TryCatchFinally
      id="guard-reviewer"
      try={
        <Sequence>
          <Task
            id={REVIEWER_DISPATCH_NODE}
            output={outputs.agentReport}
            agent={makeFlowReviewerAgent({ cwd: worktreePath, timeoutMs: REVIEWER_TIMEOUT_MS }) as never}
            retries={0}
            timeoutMs={REVIEWER_TIMEOUT_MS}
          >
            {buildReviewerPrompt(record, reviewerExcerpts(ctx, record))}
          </Task>
          {reported ? (
            <Task id="reviewer" output={outputs.reviewerVerdict} retries={0}>
              {() => {
                const raw = c.outputMaybe("agentReport", { nodeId: REVIEWER_DISPATCH_NODE }) as { report?: string } | undefined;
                const verdict = parseReviewerVerdict(raw?.report);
                return { actionableOptimization: verdict.actionableOptimization, summary: verdict.summary, cause: verdict.cause, proposedFix: verdict.proposedFix };
              }}
            </Task>
          ) : null}
        </Sequence>
      }
      catch={
        <Task id="reviewer-crashed" output={outputs.reviewerVerdict} retries={0}>
          {() => ({ actionableOptimization: false, summary: "terminal reviewer leg crashed; disposition falls back to the recorded block statuses" })}
        </Task>
      }
    />
  );
}

const REVIEWER_DISPATCH_NODE = "reviewer:dispatch";

// Every block's recorded payload, for the archive planner to mine for manifests.
// Not filtered to `proof-artifacts` by name: any block that reports a `manifest`
// array is naming files it wants preserved, and hard-coding one block name would
// silently drop a future one.
function manifestPayloads(ctx: unknown, ordered: FlowBlock[]): BlockPayload[] {
  const payloads: BlockPayload[] = [];
  for (const block of ordered) {
    const row = blockRow(ctx as CtxLike, block.id);
    if (typeof row?.payloadJson === "string") payloads.push({ blockId: block.id, payloadJson: row.payloadJson });
  }
  return payloads;
}

function isInsideWorktree(worktreePath: string, candidate: string): boolean {
  let root: string;
  let real: string;
  try {
    root = fs.realpathSync(worktreePath);
    real = fs.realpathSync(candidate);
  } catch {
    return false;
  }
  const rel = path.relative(root, real);
  return rel !== "" && !rel.startsWith("..") && !path.isAbsolute(rel);
}

function reviewerRecord(ctx: unknown, ordered: FlowBlock[], runId: string): OutcomeRecord {
  return { runId, blocks: blockOutcomes(ctx, ordered) };
}

function reviewerExcerpts(ctx: unknown, record: OutcomeRecord): string {
  return blockLogExcerpts(record, (blockId) => {
    const row = blockRow(ctx as CtxLike, blockId);
    return typeof row?.payloadJson === "string" ? row.payloadJson : undefined;
  });
}

// Either node carries the verdict: `reviewer` when the leg reported, or
// `reviewer-crashed` when the guard caught. Reading only the first would drop
// the issue file on a dead reviewer.
function reviewerVerdictRow(ctx: unknown): ReviewerVerdict | undefined {
  const c = ctx as CtxLike;
  const row = c.outputMaybe("reviewerVerdict", { nodeId: "reviewer" }) ?? c.outputMaybe("reviewerVerdict", { nodeId: "reviewer-crashed" });
  return row as unknown as ReviewerVerdict | undefined;
}

function renderIssueTask(ctx: unknown, ordered: FlowBlock[], repoPath: string, runId: string): unknown {
  const verdict = reviewerVerdictRow(ctx);
  if (verdict === undefined) return null;
  const record = reviewerRecord(ctx, ordered, runId);
  return (
    <Task id="reviewer-issue" output={outputs.issue} retries={0}>
      {() => {
        const disposition = classifyDisposition(record, verdict);
        if (!shouldWriteIssue(disposition)) {
          return { disposition, issuePath: null, redactionHits: [] };
        }
        // Written into the TARGET repo, not the staged worktree: the worktree is
        // deleted by cleanup moments later, and KD5 puts the issue where the
        // human triages it.
        const written = writeIssueFile(
          repoPath,
          buildIssueFields({
            record,
            verdict,
            disposition,
            date: new Date().toISOString().slice(0, 10),
            logExcerpts: reviewerExcerpts(ctx, record),
            evidenceArtifacts: [path.join(os.tmpdir(), "se-flow", runId, "outcome.json")],
          }),
        );
        return { disposition, issuePath: written.path, redactionHits: written.redactionHits };
      }}
    </Task>
  );
}

function renderEpilog(ctx: unknown, spec: FlowSpec, ordered: FlowBlock[], worktreePath: string, repoPath: string, workspaceNeeded: boolean, runId: string): unknown {
  return (
    <Sequence>
      <Task id="outcome" output={outputs.outcome} retries={0}>
        {() => {
          const blocks = blockOutcomes(ctx, ordered);
          const record: OutcomeRecord = { runId, blocks };
          // A run cut short by a red gate must not report the same terminal
          // state as a clean one. Recomputed here rather than captured at render
          // time so the record states the decision as it stood when the epilog
          // actually ran.
          const verdict = flowVerdict(flowDispatch(ctx, ordered));
          const archiveDir = path.join(os.tmpdir(), "se-flow", runId);
          fs.mkdirSync(archiveDir, { recursive: true });

          // KTD10: copy the named artifacts out before cleanup deletes the
          // worktree. Done ahead of the record write so the record can state
          // what the archive actually holds, not what was requested.
          const archive = copyArtifacts(
            planArtifactArchive(manifestPayloads(ctx, ordered), archiveDir, (candidate) => isInsideWorktree(worktreePath, candidate)),
          );

          // KTD13(b): redact before the write, not after — a secret written to
          // disk and cleaned up later has still been written to disk.
          //
          // What this actually guards is the spec text and the artifact paths.
          // Block payloads are deliberately NOT in the record (KTD10 defines it
          // as spec + per-block status + artifact manifest), so a secret printed
          // by a validate-cmd never reaches this file — it reaches the issue
          // file instead, which writeIssueFile redacts on its own path. The spec
          // is still a real surface: its task description is composed from
          // operator input and lands here verbatim, and later in a PR body.
          // KTD10 lists cost as part of the record. Tokens are the authoritative
          // metric and the dollar figure is an estimate (KTD6), so both are
          // written rather than the estimate alone.
          //
          // This figure excludes the epilog's own reviewer leg, which runs after
          // this task. That is the deliberate trade: writing the durable record
          // FIRST means it survives a reviewer that hangs to its 15-minute
          // timeout or dies outright. A complete cost figure is worth less than
          // a record that exists on every exit path.
          const usage = aggregateUsage(readRunUsage(runId, process.cwd(), openUsageDb));
          const { redacted, hits } = redactSecretsInText(
            JSON.stringify(
              {
                spec,
                verdict,
                record,
                cost: { totalTokens: usage.totalTokens, totalEstUsd: usage.totalEstUsd, perNode: usage.stages },
                artifacts: archive.copied.map((e) => ({ blockId: e.blockId, name: e.name, path: e.destination })),
                skippedArtifacts: archive.skipped,
              },
              null,
              2,
            ),
          );
          const recordPath = path.join(archiveDir, "outcome.json");
          fs.writeFileSync(recordPath, redacted);
          return {
            flowRunId: runId,
            recordPath,
            archiveDir,
            artifactCount: archive.copied.length,
            redactionHits: hits,
            verdict: verdict.state,
            stoppedBy: verdict.stoppedBy,
          };
        }}
      </Task>
      {renderReviewer(ctx, ordered, worktreePath, runId)}
      {renderIssueTask(ctx, ordered, repoPath, runId)}
      <Task id="cleanup" output={outputs.setup} retries={0}>
        {() => {
          if (workspaceNeeded) {
            try {
              cleanupSnapshot(repoPath, worktreePath);
            } finally {
              releaseRepoLock(repoPath, runId);
            }
          }
          return { exitCode: 0 };
        }}
      </Task>
    </Sequence>
  );
}
