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
import { createSmithers, Subflow, TryCatchFinally, type ProofBinding } from "smithers-orchestrator";
import type { WorkflowDefinition } from "@smithers-orchestrator/driver";
import { z } from "zod/v4";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { validateFlowSpec } from "./lib/flow-validate.ts";
import { buildRegistry } from "./lib/blocks/index.ts";
import { runComputeEffect, type ComputeEffectContext } from "./lib/block-effects.ts";
import { blockNodeId, dispatchableBlocks, dispatchNodeId, needsWorkspace, specHash, topoOrder } from "./lib/flow-run.ts";
import type { FlowBlock, FlowSpec } from "./lib/flow-spec.ts";
import { blockLogExcerpts, buildIssueFields, buildReviewerPrompt, classifyDisposition, parseReviewerVerdict, type BlockOutcome, type OutcomeRecord, type ReviewerVerdict } from "./lib/reviewer.ts";
import { redactSecretsInText, shouldWriteIssue, writeIssueFile } from "./lib/issue-writer.ts";
import { copyArtifacts, planArtifactArchive, type BlockPayload } from "./lib/archive.ts";
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
  runBranchName,
  stageRunWorktree,
  sweepOrphans,
  type GetRunState,
} from "./lib/staging.ts";

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

const { Workflow, Task, Sequence, smithers, outputs } = createSmithers({
  input: inputSchema,
  // Fixed prolog/epilog keys.
  gate0: z.object({ specHash: z.string(), repoPath: z.string(), needsWorkspace: z.boolean(), budgetUsd: z.number().nullish() }),
  staging: z.object({ worktreePath: z.string(), branch: z.string(), baseSha: z.string() }),
  setup: z.object({ exitCode: z.number() }),
  budget: z.object({ spentUsd: z.number(), breached: z.boolean() }),
  // flowRunId, not runId: smithers reserves runId/nodeId/iteration as internal
  // columns on every persisted node output and refuses a schema that shadows
  // them. The engine raises this at workflow construction, which `bun build`
  // cannot see — it type-checks nothing and never instantiates the workflow.
  outcome: z.object({ flowRunId: z.string(), recordPath: z.string(), archiveDir: z.string(), artifactCount: z.number(), redactionHits: z.array(z.string()) }),
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
          acquireRepoLock(repoPath, runId, getState);
          sweepOrphans(repoPath, getState);
          const st = stageRunWorktree(repoPath, branch, git(repoPath, "rev-parse", "HEAD"));
          return { worktreePath: st.worktreePath, branch: st.branch, baseSha: st.baseSha };
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
  }

  // Spec-driven block loop. Each block renders under a deterministic `b:<id>`
  // node id (KTD1); bind proofs come from the block's bindTo edges (KTD12); the
  // block's registered zod schema runtime-parses its input at dispatch (KTD14).
  const worktreePath = staged?.worktreePath ?? repoPath;
  const effectCtx: ComputeEffectContext = {
    worktreePath,
    baseSha: staged?.baseSha ?? "",
    branch: staged?.branch ?? "",
    runId,
    validateCmd: (input.validateCmd ?? "").trim(),
    validateTimeoutMs: input.validateTimeoutMs,
  };
  const subflowRun = {
    worktreePath,
    baseSha: staged?.baseSha ?? "",
    branch: staged?.branch ?? "",
    validateCmd: (input.validateCmd ?? "").trim(),
    validateTimeoutMs: input.validateTimeoutMs,
  };
  const budgetUsd = input.budgetUsd ?? 0;
  const readyGate = workspaceNeeded ? staged : gate0;
  if (readyGate) {
    for (const { block, bindNodeIds } of dispatchableBlocks(ordered, (id) => blockRowNodeId(ctx as CtxLike, id))) {
      children.push(renderBlock(ctx, block, registry, effectCtx, subflowRun, budgetUsd, bindNodeIds));
    }
  }

  // Fixed epilog on every exit path (KTD2/KTD10): outcome record + artifact
  // archive, terminal reviewer slot (U6, cannot block cleanup), cleanup + lock
  // release. Timeout-bounded; the reviewer reads only the durable record.
  const allBlocksRecorded = ordered.every((b) => blockRowNodeId(ctx as CtxLike, b.id) !== undefined);
  if (readyGate && (allBlocksRecorded || anyBlockFailed(ctx, ordered))) {
    children.push(renderEpilog(ctx, spec, ordered, worktreePath, repoPath, workspaceNeeded, runId));
  }

  return (
    <Workflow name="se-flow">
      <Sequence>{children}</Sequence>
    </Workflow>
  );
});

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
  budgetUsd: number,
  bindNodeIds: string[],
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
  if (!def || !parsedInput.success || bindings.length !== proofs.length) {
    // A dropped proof is red, never a silent unbound dispatch: dispatchableBlocks
    // withholds a block until every bindTo row exists, so a proof missing HERE
    // means the authority row disappeared between that check and this render.
    // Running the block anyway would spend it against data nothing vouches for.
    const reason = !def
      ? `block "${block.block}" is not in the registry`
      : !parsedInput.success
        ? `block "${block.id}" input failed runtime parse (KTD14)`
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
    return (
      <TryCatchFinally
        id={`guard-${block.id}`}
        try={
          <Sequence>
            <Task
              id={agentNodeId}
              output={outputs.agentReport}
              agent={def.makeAgent({ worktreePath: effectCtx.worktreePath, timeoutMs: block.timeoutMs, budgetUsd })}
              retries={block.retries}
              {...bindProps}
            >
              {def.buildPrompt(parsedInput.data)}
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

function anyBlockFailed(ctx: unknown, ordered: FlowBlock[]): boolean {
  return ordered.some((b) => {
    const out = blockRow(ctx as CtxLike, b.id);
    return out !== undefined && out.status !== "green";
  });
}

function blockOutcomes(ctx: unknown, ordered: FlowBlock[]): BlockOutcome[] {
  return ordered.map((b) => {
    const out = blockRow(ctx as CtxLike, b.id);
    return { blockId: b.id, block: b.block, status: (out?.status as BlockOutcome["status"]) ?? "non-terminal" };
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
          const { redacted, hits } = redactSecretsInText(
            JSON.stringify({ spec, record, artifacts: archive.copied.map((e) => ({ blockId: e.blockId, name: e.name, path: e.destination })), skippedArtifacts: archive.skipped }, null, 2),
          );
          const recordPath = path.join(archiveDir, "outcome.json");
          fs.writeFileSync(recordPath, redacted);
          return { flowRunId: runId, recordPath, archiveDir, artifactCount: archive.copied.length, redactionHits: hits };
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
