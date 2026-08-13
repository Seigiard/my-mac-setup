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
import { createSmithers, TryCatchFinally } from "smithers-orchestrator";
import { z } from "zod/v4";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { validateFlowSpec } from "./lib/flow-validate.ts";
import { buildRegistry } from "./lib/blocks/index.ts";
import { runComputeEffect, type ComputeEffectContext } from "./lib/block-effects.ts";
import { bindProofTargets, blockNodeId, needsWorkspace, specHash, topoOrder } from "./lib/flow-run.ts";
import type { FlowBlock, FlowSpec } from "./lib/flow-spec.ts";
import { classifyDisposition, type BlockOutcome, type OutcomeRecord } from "./lib/reviewer.ts";
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
});

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
  outcome: z.object({ runId: z.string(), recordPath: z.string(), archiveDir: z.string() }),
  reviewerVerdict: z.object({ actionableOptimization: z.boolean(), summary: z.string() }),
  // Generic per-block output.
  blockOutput: blockOutputSchema,
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
  const gate0Proof = ctx.prove(outputs.gate0, { nodeId: "gate0" });

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
      <Task id="staging" output={outputs.staging} retries={0} bind={gate0Proof}>
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
  };
  const readyGate = workspaceNeeded ? staged : gate0;
  if (readyGate) {
    for (const block of ordered) {
      children.push(renderBlock(ctx, block, registry, effectCtx));
    }
  }

  // Fixed epilog on every exit path (KTD2/KTD10): outcome record + artifact
  // archive, terminal reviewer slot (U6, cannot block cleanup), cleanup + lock
  // release. Timeout-bounded; the reviewer reads only the durable record.
  const allBlocksRecorded = ordered.every((b) => ctx.outputMaybe("blockOutput", { nodeId: blockNodeId(b.id) }) !== undefined);
  if (readyGate && (allBlocksRecorded || anyBlockFailed(ctx, ordered))) {
    children.push(renderEpilog(ctx, spec, ordered, worktreePath, repoPath, workspaceNeeded, runId));
  }

  return (
    <Workflow name="se-flow">
      <Sequence>{children}</Sequence>
    </Workflow>
  );
});

// A block becomes an engine node keyed to its kind. Compute effect bodies reuse
// the shared lib functions; agent blocks dispatch through the registered
// makeAgent + buildPrompt (KTD3); subflow blocks write a mirror key the
// interpreter copies into blockOutput.
function renderBlock(ctx: unknown, block: FlowBlock, registry: ReturnType<typeof buildRegistry>, effectCtx: ComputeEffectContext): unknown {
  const def = registry.get(block.block);
  const nodeId = blockNodeId(block.id);
  const bindTargets = bindProofTargets(block);
  const proofs = bindTargets.map((target) => (ctx as { prove: (o: unknown, opts: { nodeId: string }) => unknown }).prove(outputs.blockOutput, { nodeId: target }));

  // Runtime-parse the block's declared input (KTD14) — enforces
  // .refine()/.transform()/.nullish() semantics JSON Schema cannot express.
  const parsedInput = def ? def.inputSchema.safeParse(block.input) : { success: false as const };

  return (
    <TryCatchFinally
      id={`guard-${block.id}`}
      try={
        <Task id={nodeId} output={outputs.blockOutput} retries={block.retries} bind={proofs.length > 0 ? proofs : undefined}>
          {() => {
            if (!def) throw new Error(`block "${block.block}" vanished from the registry at dispatch`);
            if (!parsedInput.success) throw new Error(`block "${block.id}" input failed runtime parse (KTD14)`);
            const payload = dispatchBlock(def, parsedInput.data, effectCtx);
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
      catch={
        <Task id={`${nodeId}-crashed`} output={outputs.blockOutput} retries={0}>
          {() => ({ blockId: block.id, kind: def?.kind ?? "compute", status: "non-terminal" as const, payloadJson: "{}" })}
        </Task>
      }
    />
  );
}

// The per-kind execution boundary. Compute blocks run their real effect against
// the staged worktree (block-effects.ts) — the recorded shape each gateFn
// classifies. Agent and subflow dispatch is daemon-bound (makeAgent /
// dual-mode Subflow) and exercised by the plan's live fixture flow, not this
// headless build; those kinds record an empty payload here so their gateFn
// fails closed rather than passing on no result (R7).
function dispatchBlock(def: { kind: string; name: string }, input: unknown, effectCtx: ComputeEffectContext): unknown {
  if (def.kind === "compute") {
    return runComputeEffect(def.name, input, effectCtx);
  }
  return {};
}

function anyBlockFailed(ctx: unknown, ordered: FlowBlock[]): boolean {
  return ordered.some((b) => {
    const out = (ctx as { outputMaybe: (k: string, o: { nodeId: string }) => { status?: string } | undefined }).outputMaybe("blockOutput", { nodeId: blockNodeId(b.id) });
    return out !== undefined && out.status !== "green";
  });
}

function renderEpilog(ctx: unknown, spec: FlowSpec, ordered: FlowBlock[], worktreePath: string, repoPath: string, workspaceNeeded: boolean, runId: string): unknown {
  return (
    <Sequence>
      <Task id="outcome" output={outputs.outcome} retries={0}>
        {() => {
          const c = ctx as { outputMaybe: (k: string, o: { nodeId: string }) => { status?: string; payloadJson?: string } | undefined };
          const blocks: BlockOutcome[] = ordered.map((b) => {
            const out = c.outputMaybe("blockOutput", { nodeId: blockNodeId(b.id) });
            return { blockId: b.id, block: b.block, status: (out?.status as BlockOutcome["status"]) ?? "non-terminal" };
          });
          const record: OutcomeRecord = { runId, blocks };
          const archiveDir = path.join(os.tmpdir(), "se-flow", runId);
          fs.mkdirSync(archiveDir, { recursive: true });
          const recordPath = path.join(archiveDir, "outcome.json");
          fs.writeFileSync(recordPath, JSON.stringify({ spec, record }, null, 2));
          return { runId, recordPath, archiveDir };
        }}
      </Task>
      <Task id="reviewer" output={outputs.reviewerVerdict} retries={0}>
        {() => {
          const c = ctx as { outputMaybe: (k: string, o: { nodeId: string }) => { status?: string } | undefined };
          const blocks: BlockOutcome[] = ordered.map((b) => {
            const out = c.outputMaybe("blockOutput", { nodeId: blockNodeId(b.id) });
            return { blockId: b.id, block: b.block, status: (out?.status as BlockOutcome["status"]) ?? "non-terminal" };
          });
          const disposition = classifyDisposition({ runId: "epilog", blocks }, undefined);
          return { actionableOptimization: disposition === "actionable-optimization", summary: disposition };
        }}
      </Task>
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
