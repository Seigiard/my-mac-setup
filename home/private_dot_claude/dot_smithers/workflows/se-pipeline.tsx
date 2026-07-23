/** @jsxImportSource smithers-orchestrator */
// se-pipeline: durable spine verify-doc → work → verify-code over a target
// repo (env PIPELINE_REPO), from an implementation-ready ce-unified-plan/v1.
// Gates are code (lib/gates.ts), stage effects live at stage boundaries
// (lib/envelopes.ts), the run works in an isolated worktree on a named run
// branch (lib/staging.ts). Approve semantics (U1 spike verdicts): verify/work
// gates get ONE extra attempt as a fresh node, the code-review P0 gate and the
// secret-scan gate approve = waive, a second red stops the run with a report.
//
// Launch (the `se` CLI wraps this):
//   cd ~/.claude/.smithers && PIPELINE_REPO=/abs/repo DOC_REVIEW_REPO=/abs/repo \
//     ./node_modules/.bin/smithers up workflows/se-pipeline.tsx \
//     --input '{"planPath":"/abs/plan.md","until":"branch","validateCmd":"bun test"}'
import { createSmithers, ClaudeCodeAgent, OpenCodeAgent, Subflow, TryCatchFinally, approvalDecisionSchema } from "smithers-orchestrator";
import { z } from "zod/v4";
import { Database } from "bun:sqlite";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { codeReviewGate, docReviewGate, planGate, rescanGate, workGate, type GateResult, type RescanReport } from "./lib/gates.ts";
import { mergeReviewReports } from "./lib/review-merge.ts";
import { extractValidateCmd } from "./lib/plan.ts";
import { aggregateUsage, type TokenUsageEvent } from "./lib/cost.ts";
import { parseWorkEnvelope, runValidateCmd, secretScanDiff, gitHead } from "./lib/envelopes.ts";
import {
  acquireRepoLock,
  cleanupSnapshot,
  commitWorkGuarded,
  git,
  isAncestor,
  releaseRepoLock,
  runBranchName,
  stageRunWorktree,
  sweepOrphans,
  treeHash,
  type GetRunState,
} from "./lib/staging.ts";
import seDocReview from "./se-doc-review.tsx";
import type { WorkflowDefinition } from "@smithers-orchestrator/driver";

// 0.28 types Subflow's workflow prop as WorkflowDefinition<unknown>; a
// workflow typed with a concrete input schema can't satisfy it (ctx.input is
// contravariant in build). Runtime only forwards the definition, so the cast
// is safe.
const seDocReviewSubflow = seDocReview as unknown as WorkflowDefinition<unknown>;

const inputSchema = z.object({
  planPath: z.string().describe("Absolute path to the implementation-ready ce-unified-plan/v1 plan (read from the launcher, not the worktree — KTD11)."),
  until: z.enum(["branch", "pr"]).default("branch").describe("Run depth (R6); pr is a hard refusal in the MVP."),
  validateCmd: z.string().default("").describe("Target repo validation command, operator-supplied only (KTD8). Required. Keep it FAST — the work gate runs it synchronously; scope to unit/type checks, not full e2e."),
  validateTimeoutMs: z.number().default(10 * 60_000).describe("Work-gate validate-cmd timeout. A slow full-suite command (e2e) blocks the engine — scope the command instead of raising this blindly."),
  smoke: z.boolean().default(false).describe("Wiring test: trivial stage prompts, real staging/gates, no ce-work invocation."),
  workTimeoutMs: z.number().default(4 * 60 * 60_000).describe("Work leg timeout — hours, not review-sized minutes."),
  workBudgetUsd: z.number().default(50).describe("Runaway circuit breaker for the work leg, NOT a cost target; trips are logged."),
});

const docReviewSchema = z.object({
  stageDir: z.string(),
  pluginVersion: z.string(),
  claudeStatus: z.enum(["ok", "failed"]),
  opencodeStatus: z.enum(["ok", "failed"]),
  claudeEnvelopePath: z.string().optional(),
  opencodeEnvelopePath: z.string().optional(),
});

const gateVerdictSchema = z.object({
  stage: z.string(),
  state: z.enum(["green", "failed", "degraded"]),
  reasons: z.string(),
  p1Count: z.number().optional(),
});

const { Workflow, Task, Sequence, Parallel, Approval, smithers, outputs } = createSmithers({
  input: inputSchema,
  gate0: z.object({ planHash: z.string(), planPath: z.string(), until: z.string(), validateCmd: z.string(), validateTimeoutMs: z.number(), repoPath: z.string() }),
  staging: z.object({ worktreePath: z.string(), branch: z.string(), baseSha: z.string() }),
  docReview: docReviewSchema,
  agentReport: z.object({ report: z.string() }),
  failedMarker: z.object({ stage: z.string() }),
  gateVerdict: gateVerdictSchema,
  approval: approvalDecisionSchema,
  prep: z.object({ stage: z.string(), didReset: z.boolean(), resetTo: z.string() }),
  summary: z.object({
    verdict: z.string(),
    planPath: z.string(),
    planHash: z.string(),
    branch: z.string(),
    baseSha: z.string(),
    headSha: z.string(),
    stages: z.string(),
    notes: z.string(),
    reportDir: z.string(),
    // Single authoritative cost store (KTD6/U6): tokens are ground truth,
    // estCostUsd is a price-table approximation (lib/cost.ts).
    totalTokens: z.number(),
    estCostUsd: z.number(),
    stageUsage: z.string(),
  }),
});

const repoDir = process.env.PIPELINE_REPO ?? process.cwd();

// Per-leg caps sized from _smithers_attempts history (same arithmetic as
// se-code-review.tsx): the claude leg's full plugin review blows a 15-min cap
// on big diffs; opencode finishes in 3-6 min. The verify-code merge node is
// pure compute.
const CLAUDE_REVIEW_TIMEOUT_MS = 25 * 60_000;
const OPENCODE_REVIEW_TIMEOUT_MS = 15 * 60_000;

// Model profile (Balanced): Opus for implementation, Sonnet for review — never
// Fable. fallbackModel auto-switches when the primary is rate-limited, riding
// out a Max-subscription throttle instead of failing the stage.
const WORK_MODEL = "claude-opus-4-8";
const WORK_FALLBACK_MODEL = "claude-sonnet-5";
const REVIEW_MODEL = "claude-sonnet-5";
const REVIEW_FALLBACK_MODEL = "claude-haiku-4-5";

// Native structured-output enforcement (claude CLI --json-schema); smithers
// does not derive it from the Task's Zod schema. Default stream-json capture
// is fine on 0.27.0 (KTD9 verdict, U1 spike run a9b4b686) — no outputFormat
// override here.
const reportJsonSchema = JSON.stringify({
  type: "object",
  properties: { report: { type: "string" } },
  required: ["report"],
});

// Lock/sweep staleness is decided by run STATE in smithers.db (cwd = the
// smithers dir), never pid liveness: an Approval pause has no live process
// but still owns its lock and worktree. Unknown runIds count as terminal.
function makeGetRunState(): GetRunState {
  return (runId) => {
    try {
      const db = new Database(path.join(process.cwd(), "smithers.db"), { readonly: true });
      try {
        // Exact match for full runIds (lock holders); tail match for the
        // 8-char alphanumeric tails parsed from run branch names. Dashes are
        // stripped from tails, so compare against a dash-less run_id.
        const row = db
          .query(
            "SELECT status FROM _smithers_runs WHERE run_id = ?1 OR replace(run_id, '-', '') LIKE '%' || ?1 ORDER BY length(run_id) ASC LIMIT 1",
          )
          .get(runId) as { status?: string } | null;
        if (!row?.status) return undefined;
        if (row.status === "running") return "running";
        if (row.status === "waiting-approval") return "waiting-approval";
        if (["finished", "failed", "cancelled", "canceled"].includes(row.status)) return "terminal";
        return "interrupted-resumable";
      } finally {
        db.close();
      }
    } catch (err) {
      // Fail CLOSED: an unreadable store must never read as "terminal" — that
      // would let acquireRepoLock steal a live run's lock and sweepOrphans
      // destroy its worktree. A genuine missing row returns undefined (terminal)
      // inside the try; only a DB/query ERROR lands here, and it holds the lock.
      console.error(`makeGetRunState: smithers.db unreadable for ${runId}, treating as live (fail-closed): ${err instanceof Error ? err.message : String(err)}`);
      return "running";
    }
  };
}

// Per-stage token usage for this run and its subflow children, read from the
// persisted event log (the only place 0.27.0 keeps usage — U1 verdict, е).
function readRunUsage(runId: string): TokenUsageEvent[] {
  // 0.28's walk-up state resolver can persist smithers.db a level ABOVE the
  // launch dir (a runtime dir literally named `.smithers` reads as another
  // project's state dir), and a fresh 0.28 database has no _smithers_events
  // table until the first event lands. Cost is advisory (KTD6: tokens are the
  // metric, USD an estimate) — the summary task must never fail the run over
  // missing telemetry: resolve the db upward and fail soft to zero usage.
  const cwd = process.cwd();
  const candidates = [cwd, path.dirname(cwd)].map((d) => path.join(d, "smithers.db"));
  for (const dbPath of candidates) {
    let db: Database;
    try {
      if (!fs.existsSync(dbPath) || fs.statSync(dbPath).size === 0) continue;
      db = new Database(dbPath, { readonly: true });
    } catch {
      continue;
    }
    try {
      const rows = db
        .query("SELECT payload_json FROM _smithers_events WHERE type='TokenUsageReported' AND (run_id = ?1 OR run_id LIKE ?1 || ':child:%')")
        .all(runId) as Array<{ payload_json: string }>;
      return rows.map((row) => {
        const p = JSON.parse(row.payload_json) as Record<string, unknown>;
        return {
          nodeId: String(p.nodeId ?? "unknown"),
          model: typeof p.model === "string" ? p.model : null,
          inputTokens: Number(p.inputTokens ?? 0),
          outputTokens: Number(p.outputTokens ?? 0),
          cacheReadTokens: Number(p.cacheReadTokens ?? 0),
          cacheWriteTokens: Number(p.cacheWriteTokens ?? 0),
        };
      });
    } catch {
      continue;
    } finally {
      db.close();
    }
  }
  return [];
}

// The opencode review leg has no claude plugin skills — stage a copy of the
// plugin's ce-code-review skill under /tmp/ce-code-review, the tmp root
// opencode's permission.external_directory allows (the run worktree itself is
// its cwd and needs no allow). Same layout as se-code-review.tsx staging.
function resolvePluginSkillDir(): { dir: string; version: string } {
  const base = path.join(os.homedir(), ".claude/plugins/cache/compound-engineering-plugin/compound-engineering");
  const versions = fs.readdirSync(base).sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
  const latest = versions[versions.length - 1];
  return { dir: path.join(base, latest, "skills/ce-code-review"), version: latest };
}

function stageCodeReviewConsult(tag: string): { skillDir: string; pluginVersion: string } {
  const stageDir = path.join("/tmp/ce-code-review", `pipeline-${tag}-${Date.now()}`);
  const skillDir = path.join(stageDir, "skill");
  fs.mkdirSync(skillDir, { recursive: true });
  const plugin = resolvePluginSkillDir();
  fs.cpSync(plugin.dir, skillDir, { recursive: true });
  return { skillDir, pluginVersion: plugin.version };
}

function workPrompt(planPath: string, branch: string, smoke: boolean): string {
  if (smoke) {
    return `[se-pipeline-stage] Smoke wiring test. Your cwd is an isolated git worktree on branch ${branch}. Do exactly this: append one line to SMOKE.md. Do NOT run git add/commit/push — leave the change in the working tree; the pipeline commits it. Your FINAL message must be EXACTLY one JSON object {"report": "<envelope>"} where <envelope> is a JSON object serialized as a string with fields: status="complete", changed_files=["SMOKE.md"], u_ids_attempted=[], u_ids_completed=[], verification_evidence=[{"unit":"smoke","exception_reason":"smoke wiring test"}], blockers=[], behavior_change=false, standalone_shipping_skipped=true.`;
  }
  return `[se-pipeline-stage]

Invoke the skill compound-engineering:ce-work with args "mode:return-to-caller ${planPath}".

Context: your cwd is an ISOLATED git worktree of the target repository, already on the run branch ${branch} — continue on this branch, do NOT ask about branches, do NOT create worktrees, never push. Fully headless: never ask questions; make every decision yourself.

Do NOT commit and do NOT run git add/commit/push: leave ALL your changes in the working tree exactly as edited. The pipeline commits your work itself, deterministically, after this step — this keeps commits idempotent across crash-resume (KTD5). This instruction overrides any ce-work step that would otherwise commit.

Your FINAL message must be EXACTLY one JSON object and nothing else: {"report": "<the skill's return-to-caller envelope (status, plan_path, changed_files, u_ids_attempted, u_ids_completed, verification_results, verification_evidence, blockers, behavior_change, standalone_shipping_skipped) serialized as a string>"}.`;
}

function codeReviewPrompt(baseSha: string, branch: string, skillDir: string, smoke: boolean): string {
  if (smoke) {
    return `[se-pipeline-stage] Smoke wiring test. Your FINAL message must be EXACTLY one JSON object: {"report": "<the JSON object {\\"status\\":\\"complete\\",\\"verdict\\":\\"approve\\",\\"findings\\":[]} serialized as a string>"}. Do nothing else.`;
  }
  return `[se-pipeline-stage]

Execute the compound-engineering code-review workflow in mode:agent on YOUR CURRENT working directory — it is the pipeline's isolated worktree on run branch ${branch}.

How to execute it:
- If your available skills include \`compound-engineering:ce-code-review\`, invoke it with args "mode:agent base:${baseSha}".
- Otherwise, read ${skillDir}/SKILL.md and follow it directly, treating ${skillDir} as the skill's base directory (it references its own files under it). Where it dispatches subagents, use YOUR subagent tool.
- Review target: the commits on this branch since ${baseSha}.

Hard rules:
- NEVER invoke skills named bare \`se-code-review\` or \`se-pipeline\` — they spawn orchestrations and would recurse.
- NO CHANGES, JUST REPORT: mode:agent is report-only. Do not create, edit, or delete ANY file, never commit, never push, never switch branches.
- Your FINAL message must be EXACTLY one JSON object and nothing else: {"report": "<the plugin's full mode:agent JSON review (status/verdict/findings/...) serialized as a string>"}. A final message that is not that single JSON object is a failed run.`;
}

type StageStatus = "pending" | "green" | "stopped";

interface StageBlock {
  nodes: unknown[];
  status: StageStatus;
  waived: boolean;
  verdict?: z.infer<typeof gateVerdictSchema>;
}

export default smithers((ctx) => {
  const input = ctx.input;
  // ctx.input arrives WITHOUT Zod defaults applied — coalesce every optional.
  const until = input.until ?? "branch";
  const validateCmd = input.validateCmd ?? "";
  const validateTimeoutMs = input.validateTimeoutMs ?? 10 * 60_000;
  const smoke = input.smoke ?? false;
  const workTimeoutMs = input.workTimeoutMs ?? 4 * 60 * 60_000;
  const workBudgetUsd = input.workBudgetUsd ?? 50;

  const gate0 = ctx.outputMaybe("gate0", { nodeId: "gate0" });
  const staged = ctx.outputMaybe("staging", { nodeId: "staging" });

  // ProofBinding chain (R1/KTD-A/KTD-B): digest the persisted gate-0 output row
  // (the plan-hash authority) and bind the expensive legs to it. The engine
  // re-verifies at every render and immediately before every dispatch; a later
  // mutation of the gate0 row (bug, manual sqlite edit, partial restore) flips
  // the bound tasks to bound-stale and parks the run (BOUND_STALE / waiting-event)
  // without consuming retries — resume after re-producing the authority row or
  // reverting the mutation. Pure at render time; undefined until gate0 exists
  // (work renders only after gate0, so authoring bind never strands scheduling).
  // Provenance is row-chain integrity ONLY — it reads no filesystem, so
  // workGateFn's plan-file re-hash stays the file guard (R2).
  const gate0Proof = ctx.prove(outputs.gate0, { nodeId: "gate0" });

  const toVerdict = (stage: string, r: GateResult): z.infer<typeof gateVerdictSchema> => ({
    stage,
    state: r.state,
    reasons: r.reasons.join("; "),
    ...(r.p1Count === undefined ? {} : { p1Count: r.p1Count }),
  });

  // One stage = attempt → gate → (red) Approval → extra attempt as a FRESH
  // node → gate → (red again) abort-only Approval (stop with report, R3).
  // waiveOnApprove switches the first Approval to waive-and-continue (KTD3 G3,
  // KTD10 secret-scan). extraPrep runs before the extra attempt (KTD5 work
  // branch reset).
  function stageBlock(opts: {
    name: string;
    makeAttempt: (nodeId: string) => unknown;
    readRaw: (nodeId: string) => { present: boolean; raw: string | undefined };
    gateFn: (raw: string | undefined) => GateResult;
    waiveOnApprove: boolean;
    makeExtraPrep?: (nodeId: string) => unknown;
  }): StageBlock {
    const { name } = opts;
    const nodes: unknown[] = [];
    const att1 = opts.readRaw(name);
    const crash1 = ctx.outputMaybe("failedMarker", { nodeId: `${name}-crashed` });
    const v1 = ctx.outputMaybe("gateVerdict", { nodeId: `gate-${name}` });
    const ap1 = ctx.outputMaybe("approval", { nodeId: `approve-${name}-1` });
    const prepDone = ctx.outputMaybe("prep", { nodeId: `${name}-extra-prep` });
    const att2 = opts.readRaw(`${name}-extra`);
    const crash2 = ctx.outputMaybe("failedMarker", { nodeId: `${name}-extra-crashed` });
    const v2 = ctx.outputMaybe("gateVerdict", { nodeId: `gate-${name}-extra` });
    const ap2 = ctx.outputMaybe("approval", { nodeId: `approve-${name}-2` });

    nodes.push(
      <TryCatchFinally
        id={`guard-${name}`}
        try={opts.makeAttempt(name)}
        catch={
          <Task id={`${name}-crashed`} output={outputs.failedMarker}>
            {() => ({ stage: name })}
          </Task>
        }
      />,
    );
    if (att1.present || crash1) {
      nodes.push(
        <Task id={`gate-${name}`} output={outputs.gateVerdict} retries={0}>
          {() => toVerdict(name, opts.gateFn(att1.raw))}
        </Task>,
      );
    }
    if (!v1) return { nodes, status: "pending", waived: false };
    if (v1.state === "green") return { nodes, status: "green", waived: false, verdict: v1 };

    nodes.push(
      <Approval
        id={`approve-${name}-1`}
        output={outputs.approval}
        request={{
          title: `${name} gate is ${v1.state} — ${opts.waiveOnApprove ? "approve to WAIVE and continue" : "approve ONE extra attempt"}; deny aborts the run`,
          summary: v1.reasons,
        }}
        onDeny="fail"
      />,
    );
    if (!ap1?.approved) return { nodes, status: "pending", waived: false, verdict: v1 };
    if (opts.waiveOnApprove) return { nodes, status: "green", waived: true, verdict: v1 };

    if (opts.makeExtraPrep) {
      nodes.push(opts.makeExtraPrep(`${name}-extra-prep`));
      if (!prepDone) return { nodes, status: "pending", waived: false, verdict: v1 };
    }
    nodes.push(
      <TryCatchFinally
        id={`guard-${name}-extra`}
        try={opts.makeAttempt(`${name}-extra`)}
        catch={
          <Task id={`${name}-extra-crashed`} output={outputs.failedMarker}>
            {() => ({ stage: name })}
          </Task>
        }
      />,
    );
    if (att2.present || crash2) {
      nodes.push(
        <Task id={`gate-${name}-extra`} output={outputs.gateVerdict} retries={0}>
          {() => toVerdict(name, opts.gateFn(att2.raw))}
        </Task>,
      );
    }
    if (!v2) return { nodes, status: "pending", waived: false, verdict: v1 };
    if (v2.state === "green") return { nodes, status: "green", waived: false, verdict: v2 };

    nodes.push(
      <Approval
        id={`approve-${name}-2`}
        output={outputs.approval}
        request={{
          title: `${name} failed the extra attempt — abort only: approve stops the run WITH a report, deny fails it`,
          summary: v2.reasons,
        }}
        onDeny="fail"
      />,
    );
    if (!ap2?.approved) return { nodes, status: "pending", waived: false, verdict: v2 };
    return { nodes, status: "stopped", waived: false, verdict: v2 };
  }

  const readAgentReport = (nodeId: string): { present: boolean; raw: string | undefined } => {
    const out = ctx.outputMaybe("agentReport", { nodeId });
    return { present: out !== undefined, raw: out?.report };
  };

  const readDocReview = (nodeId: string): { present: boolean; raw: string | undefined } => {
    const out = ctx.outputMaybe("docReview", { nodeId });
    return { present: out !== undefined, raw: out === undefined ? undefined : JSON.stringify(out) };
  };

  // Agents are built per render — their cwd (the run worktree) exists only
  // after the staging task runs.
  const workAgent = staged
    ? new ClaudeCodeAgent({
        cwd: staged.worktreePath,
        permissionMode: "bypassPermissions",
        dangerouslySkipPermissions: true,
        model: WORK_MODEL,
        fallbackModel: WORK_FALLBACK_MODEL,
        timeoutMs: workTimeoutMs,
        maxBudgetUsd: workBudgetUsd,
        jsonSchema: reportJsonSchema,
      })
    : undefined;
  const codeReviewAgent = staged
    ? new ClaudeCodeAgent({
        cwd: staged.worktreePath,
        permissionMode: "acceptEdits",
        model: REVIEW_MODEL,
        fallbackModel: REVIEW_FALLBACK_MODEL,
        timeoutMs: CLAUDE_REVIEW_TIMEOUT_MS,
        maxBudgetUsd: 15,
        jsonSchema: reportJsonSchema,
      })
    : undefined;
  const opencodeReviewAgent = staged
    ? new OpenCodeAgent({
        cwd: staged.worktreePath,
        model: "openai/gpt-5.5",
        timeoutMs: OPENCODE_REVIEW_TIMEOUT_MS,
      })
    : undefined;

  const children: unknown[] = [
    <Task id="gate0" output={outputs.gate0} retries={0}>
      {() => {
        let markdown: string;
        try {
          markdown = fs.readFileSync(input.planPath, "utf8");
        } catch {
          throw new Error(`gate-0 refused: cannot read plan at ${input.planPath} (AE4)`);
        }
        const result = planGate(markdown, until);
        if (!result.ok) throw new Error(`gate-0 refused: ${result.reason}`);
        // Resolve the validate command: explicit --validate-cmd wins; otherwise
        // derive it from the plan's own Verification Contract (KTD8: the plan is
        // a trusted operator input — deriving from it is safe, unlike reading a
        // command from the target repo's config).
        let resolvedValidateCmd = validateCmd.trim();
        let validateSource = "operator (--validate-cmd)";
        if (resolvedValidateCmd === "") {
          const derived = extractValidateCmd(markdown);
          if (derived === null) {
            throw new Error("gate-0 refused: no --validate-cmd given and the plan's Verification Contract has no runnable commands to derive one from. Add a Verification Contract with test/typecheck commands, or pass --validate-cmd explicitly.");
          }
          resolvedValidateCmd = derived;
          validateSource = "plan Verification Contract";
        }
        console.error(`se-pipeline: work-gate validate-cmd [${validateSource}]: ${resolvedValidateCmd}`);
        if (git(repoDir, "status", "--porcelain") !== "") {
          console.error(`se-pipeline preflight: target repo ${repoDir} has a dirty working tree — the run works from committed HEAD only (KTD11); operator WIP is not included.`);
        }
        return { planHash: result.hash, planPath: input.planPath, until, validateCmd: resolvedValidateCmd, validateTimeoutMs, repoPath: repoDir };
      }}
    </Task>,
  ];

  const notes: string[] = [];
  let terminal: string | undefined;

  if (gate0) {
    children.push(
      <Task id="staging" output={outputs.staging} retries={0}>
        {() => {
          const getRunState = makeGetRunState();
          const lock = acquireRepoLock(repoDir, ctx.runId, getRunState);
          if (!lock.acquired && lock.holderRunId !== ctx.runId) {
            throw new Error(`repo lock is held by run ${lock.holderRunId} (state ${lock.holderState ?? "unknown"}) — one pipeline run per repo. Wait for it or abort it first.`);
          }
          sweepOrphans(repoDir, getRunState);
          const slug = path.basename(input.planPath).replace(/\.[^.]+$/, "");
          const branch = runBranchName(slug, ctx.runId);
          // Idempotent re-run after an interrupted staging attempt: the branch
          // exists with no work commits yet — reuse it and its worktree.
          try {
            git(repoDir, "rev-parse", "--verify", "--quiet", `refs/heads/${branch}`);
            const worktreePath = path.join(os.tmpdir(), "se-pipeline", branch.replace(/\//g, "-"));
            if (!fs.existsSync(worktreePath)) {
              throw new Error(`run branch ${branch} exists but its worktree is missing — remove the branch or sweep before retrying.`);
            }
            return { worktreePath, branch, baseSha: git(repoDir, "rev-parse", branch) };
          } catch (err) {
            if (err instanceof Error && err.message.includes("worktree is missing")) throw err;
          }
          return stageRunWorktree(repoDir, branch, git(repoDir, "rev-parse", "HEAD"));
        }}
      </Task>,
    );
  }

  if (gate0 && staged) {
    const doc = stageBlock({
      name: "verify-doc",
      makeAttempt: (nodeId) => (
        <Subflow
          id={nodeId}
          workflow={seDocReviewSubflow}
          input={{ docPath: input.planPath, smoke }}
          output={outputs.docReview}
          retries={1}
          // Hang guard, not a scheduler: must fit the claude leg's own retry
          // ladder (2 × 25 min) plus synthesis margin. A cap equal to the leg
          // cap killed run-1784730393057 mid-retry after one envelope fail.
          timeoutMs={55 * 60_000}
        />
      ),
      readRaw: readDocReview,
      gateFn: (raw) => docReviewGate(raw === undefined ? undefined : JSON.parse(raw)),
      waiveOnApprove: false,
    });
    children.push(...(doc.nodes as never[]));
    if (doc.status === "stopped") terminal = "stopped-after-second-failure:verify-doc";
    if (doc.status === "green") {
      if (doc.verdict?.reasons) notes.push(`verify-doc: ${doc.verdict.reasons}`);

      // Work gate runs the effects itself: it commits the agent's work, then
      // proves the work by comparing tree hashes and running the operator's
      // validate-cmd in the worktree — agent self-report is never ground truth
      // (KTD3). Plan hash is re-checked so a plan edited during an Approval
      // pause fails loudly (KTD7).
      const workGateFn = (raw: string | undefined): GateResult => {
        const planNow = fs.readFileSync(gate0.planPath, "utf8");
        const planCheck = planGate(planNow, gate0.until);
        if (!planCheck.ok || planCheck.hash !== gate0.planHash) {
          return { state: "failed", reasons: [`plan content changed during the run (hash mismatch) — refusing to gate work against a stale spec (KTD7)`] };
        }
        const baseTree = treeHash(repoDir, staged.baseSha);
        // Deterministic guarded commit (KTD5): the work agent leaves its changes
        // uncommitted; the pipeline commits them here, exactly once. Commits
        // belong to the pipeline, never the agent, so a re-run agent cannot
        // double them; commitWorkGuarded is a no-op on a clean tree, so a resume
        // that re-runs this task after the commit persisted adds nothing.
        if (raw !== undefined) {
          commitWorkGuarded(staged.worktreePath, `se-pipeline: work stage on ${staged.branch}`);
        }
        const headTree = treeHash(staged.worktreePath);
        const validate = raw === undefined ? null : runValidateCmd(gate0.validateCmd, staged.worktreePath, gate0.validateTimeoutMs);
        const result = workGate({ raw, baseTree, headTree, validateExitCode: validate === null ? null : validate.exitCode });
        if (validate !== null && validate.exitCode !== 0) {
          result.reasons.push(`validate-cmd output tail: ${validate.output.slice(-500)}`);
        }
        return result;
      };

      const work = stageBlock({
        name: "work",
        makeAttempt: (nodeId) => (
          // KTD5: no blind retry for work — a crashed work leg goes straight
          // to Approval, not into a silent multi-hour re-run. bind (KTD-B):
          // both work and work-extra fence the costly agent leg behind the
          // gate-0 authority row — a tampered plan-hash parks BOUND_STALE
          // before dispatch.
          <Task id={nodeId} output={outputs.agentReport} agent={workAgent} retries={0} bind={gate0Proof}>
            {workPrompt(gate0.planPath, staged.branch, smoke)}
          </Task>
        ),
        readRaw: readAgentReport,
        gateFn: workGateFn,
        waiveOnApprove: false,
        // KTD5 conditional reset before the approved extra attempt: envelope
        // present → untouched branch (ce-work idempotency path inspects the
        // existing work); no envelope → deterministic reset to pre-stage SHA.
        makeExtraPrep: (nodeId) => (
          <Task id={nodeId} output={outputs.prep} retries={0}>
            {() => {
              const first = ctx.outputMaybe("agentReport", { nodeId: "work" });
              const parsed = parseWorkEnvelope(first?.report);
              const moved = gitHead(staged.worktreePath) !== staged.baseSha;
              const dirty = git(staged.worktreePath, "status", "--porcelain") !== "";
              // KTD5 conditional reset: a first attempt with no valid envelope is
              // discarded — reset the branch to the pre-stage SHA and clear
              // untracked files (which survive reset --hard) so the extra attempt
              // starts clean, whether the gate committed a bad attempt (moved) or
              // the agent crashed leaving the tree dirty. A valid envelope (gate
              // red on validate, not a broken run) keeps its committed work for
              // ce-work's idempotency path.
              if (!parsed.ok && (moved || dirty)) {
                git(staged.worktreePath, "reset", "--hard", staged.baseSha);
                git(staged.worktreePath, "clean", "-fd");
                return { stage: "work", didReset: true, resetTo: staged.baseSha };
              }
              return { stage: "work", didReset: false, resetTo: staged.baseSha };
            }}
          </Task>
        ),
      });
      children.push(...(work.nodes as never[]));
      if (work.status === "stopped") terminal = "stopped-after-second-failure:work";
      if (work.status === "green") {
        // Secret-scan the run branch diff BEFORE anything is sent to external
        // LLMs (KTD10). Scanner errors are degraded, never a silent pass.
        const scan = stageBlock({
          name: "secret-scan",
          makeAttempt: (nodeId) => (
            <Task id={nodeId} output={outputs.agentReport} retries={0} bind={gate0Proof}>
              {() => {
                const result = secretScanDiff(staged.worktreePath, staged.baseSha);
                // scannedHead threads the SHA scanned here to the post-approval
                // rescan (KTD-D): if the branch HEAD later moves during a
                // verify-code pause, the rescan re-scans + re-validates the new
                // commits. Lives in the report JSON, not a new schema column.
                return { report: JSON.stringify({ ...result, scannedHead: gitHead(staged.worktreePath) }) };
              }}
            </Task>
          ),
          readRaw: readAgentReport,
          gateFn: (raw) => {
            if (raw === undefined) return { state: "failed", reasons: ["secret-scan task produced no result"] };
            const result = JSON.parse(raw) as { state: string; details: string };
            if (result.state === "clean") return { state: "green", reasons: [] };
            return {
              state: "degraded",
              reasons: [result.state === "found" ? `secret-scan found leaks in the run diff: ${result.details.slice(0, 500)}` : `secret-scan could not run: ${result.details.slice(0, 500)}`],
            };
          },
          waiveOnApprove: true,
        });
        children.push(...(scan.nodes as never[]));
        if (scan.status === "stopped") terminal = "stopped-after-second-failure:secret-scan";
        if (scan.status === "green") {
          if (scan.waived) notes.push(`secret-scan: waived by operator — ${scan.verdict?.reasons ?? ""}`);

          // verify-code mirrors se-code-review's harness shape: two independent
          // full plugin reviews in parallel (claude + opencode, each with its
          // own guard so one engine failing never kills the stage), then a
          // deterministic merge (lib/review-merge.ts) lands on the stage's own
          // nodeId — stageBlock, codeReviewGate, and the summary read the merged
          // report exactly where the single-leg report used to live.
          const code = stageBlock({
            name: "verify-code",
            makeAttempt: (nodeId) => {
              const consultOut = ctx.outputMaybe("agentReport", { nodeId: `${nodeId}-consult-stage` });
              const consult = consultOut === undefined ? undefined : (JSON.parse(consultOut.report) as { skillDir: string });
              const claudeOut = ctx.outputMaybe("agentReport", { nodeId: `${nodeId}-claude` });
              const claudeCrash = ctx.outputMaybe("failedMarker", { nodeId: `${nodeId}-claude-crashed` });
              const opencodeOut = ctx.outputMaybe("agentReport", { nodeId: `${nodeId}-opencode` });
              const opencodeCrash = ctx.outputMaybe("failedMarker", { nodeId: `${nodeId}-opencode-crashed` });
              const legsSettled = (claudeOut !== undefined || claudeCrash !== undefined) && (opencodeOut !== undefined || opencodeCrash !== undefined);
              return (
                <Sequence>
                  <Task id={`${nodeId}-consult-stage`} output={outputs.agentReport} retries={0}>
                    {() => ({ report: JSON.stringify(stageCodeReviewConsult(nodeId)) })}
                  </Task>
                  {consult ? (
                    <Parallel>
                      <TryCatchFinally
                        id={`guard-${nodeId}-claude`}
                        try={
                          <Task id={`${nodeId}-claude`} output={outputs.agentReport} agent={codeReviewAgent} retries={1} bind={gate0Proof}>
                            {codeReviewPrompt(staged.baseSha, staged.branch, consult.skillDir, smoke)}
                          </Task>
                        }
                        catch={
                          <Task id={`${nodeId}-claude-crashed`} output={outputs.failedMarker}>
                            {() => ({ stage: `${nodeId}-claude` })}
                          </Task>
                        }
                      />
                      <TryCatchFinally
                        id={`guard-${nodeId}-opencode`}
                        try={
                          <Task id={`${nodeId}-opencode`} output={outputs.agentReport} agent={opencodeReviewAgent} retries={1} bind={gate0Proof}>
                            {codeReviewPrompt(staged.baseSha, staged.branch, consult.skillDir, smoke)}
                          </Task>
                        }
                        catch={
                          <Task id={`${nodeId}-opencode-crashed`} output={outputs.failedMarker}>
                            {() => ({ stage: `${nodeId}-opencode` })}
                          </Task>
                        }
                      />
                    </Parallel>
                  ) : null}
                  {consult && legsSettled ? (
                    <Task id={nodeId} output={outputs.agentReport} retries={0}>
                      {() => ({
                        report: mergeReviewReports([
                          { source: "claude", raw: claudeOut?.report },
                          { source: "opencode", raw: opencodeOut?.report },
                        ]),
                      })}
                    </Task>
                  ) : null}
                </Sequence>
              );
            },
            readRaw: readAgentReport,
            gateFn: (raw) => codeReviewGate({ raw }),
            waiveOnApprove: true,
          });
          children.push(...(code.nodes as never[]));
          if (code.status === "stopped") terminal = "stopped-after-second-failure:verify-code";
          if (code.status === "green") {
            if (code.waived) notes.push(`verify-code: P0 waived by operator — ${code.verdict?.reasons ?? ""}`);
            else if (code.verdict?.reasons) notes.push(`verify-code: ${code.verdict.reasons}`);

            // Post-approval rescan (R3–R6): operators often hand-commit fixes on
            // the run branch during the verify-code pause; those commits bypass
            // the earlier secret-scan (base..HEAD) and the work-gate validate-cmd.
            // The compute attempt reads the SHA scanned by secret-scan (KTD-D);
            // if the worktree HEAD moved (or scannedHead is absent — fail-closed),
            // it re-runs secretScanDiff + runValidateCmd on the new commits. All
            // git/fs reads stay inside the closure (KTD-E render purity). Waive
            // fits the actor — the red is the operator's own commits (mirrors
            // secret-scan waive); a second red stops with a report (stageBlock).
            // Both proofs exist by this point (secret-scan and verify-code are
            // green behind us); binding the rescan to the scan row makes a
            // mutated scannedHead park BOUND_STALE instead of yielding a
            // false-clean no-op (the tamper vector the rescan itself guards).
            const scanProof =
              ctx.prove(outputs.agentReport, { nodeId: "secret-scan-extra" }) ??
              ctx.prove(outputs.agentReport, { nodeId: "secret-scan" });
            const rescanBind = [gate0Proof, scanProof].filter((b) => b !== undefined);
            const rescan = stageBlock({
              name: "rescan",
              makeAttempt: (nodeId) => (
                <Task id={nodeId} output={outputs.agentReport} retries={0} bind={rescanBind as never}>
                  {() => {
                    const prior = ctx.outputMaybe("agentReport", { nodeId: "secret-scan-extra" }) ?? ctx.outputMaybe("agentReport", { nodeId: "secret-scan" });
                    let scannedHead: string | undefined;
                    if (prior?.report) {
                      try {
                        scannedHead = (JSON.parse(prior.report) as { scannedHead?: string }).scannedHead;
                      } catch {
                        scannedHead = undefined;
                      }
                    }
                    const currentHead = gitHead(staged.worktreePath);
                    const moved = scannedHead === undefined || currentHead !== scannedHead;
                    if (!moved) {
                      return { report: JSON.stringify({ moved: false, scannedHead, currentHead } satisfies RescanReport) };
                    }
                    // Scan only the operator's new commits when ancestry holds:
                    // base..scannedHead findings were already adjudicated (a
                    // waived secret must not re-flag and train blind approves).
                    // Rebase/amend during the pause breaks ancestry → full range,
                    // fail-closed.
                    const scanBase = scannedHead !== undefined && isAncestor(staged.worktreePath, scannedHead, "HEAD") ? scannedHead : staged.baseSha;
                    const scan = secretScanDiff(staged.worktreePath, scanBase);
                    const validate = runValidateCmd(gate0.validateCmd, staged.worktreePath, gate0.validateTimeoutMs);
                    return { report: JSON.stringify({ moved: true, scan, validateExitCode: validate.exitCode, scannedHead, currentHead, scanBase } satisfies RescanReport) };
                  }}
                </Task>
              ),
              readRaw: readAgentReport,
              gateFn: (raw) => rescanGate({ raw }),
              // NOT a waive gate: approve = ONE fresh attempt that re-reads HEAD
              // and re-scans — the natural operator flow on a red rescan is
              // "commit the fix, approve", and the fix-commit must itself be
              // scanned (the recursion the waive shape could never close). A
              // second red stops with a report; commits made after the final
              // green attempt are the documented regress stop.
              waiveOnApprove: false,
            });
            children.push(...(rescan.nodes as never[]));
            if (rescan.status === "stopped") terminal = "stopped-after-second-failure:rescan";
            if (rescan.status === "green") {
              if (rescan.verdict?.reasons) notes.push(`rescan: ${rescan.verdict.reasons}`);
              terminal = "green";
            }
          }
        }
      }
    }
  }

  if (terminal && gate0 && staged) {
    const t = terminal;
    const stages: Record<string, unknown> = {};
    for (const stage of ["verify-doc", "work", "secret-scan", "verify-code", "rescan"]) {
      const extra = ctx.outputMaybe("gateVerdict", { nodeId: `gate-${stage}-extra` });
      const first = ctx.outputMaybe("gateVerdict", { nodeId: `gate-${stage}` });
      stages[stage] = extra ?? first ?? null;
    }
    const workReport = ctx.outputMaybe("agentReport", { nodeId: "work-extra" }) ?? ctx.outputMaybe("agentReport", { nodeId: "work" });
    const codeReport = ctx.outputMaybe("agentReport", { nodeId: "verify-code-extra" }) ?? ctx.outputMaybe("agentReport", { nodeId: "verify-code" });
    // Per-leg reports of the attempt the gate actually used — the merged report
    // strips nothing, but humans at the Approval pause want each engine's view.
    const codeAttempt = ctx.outputMaybe("agentReport", { nodeId: "verify-code-extra" }) !== undefined ? "verify-code-extra" : "verify-code";
    const codeClaudeReport = ctx.outputMaybe("agentReport", { nodeId: `${codeAttempt}-claude` });
    const codeOpencodeReport = ctx.outputMaybe("agentReport", { nodeId: `${codeAttempt}-opencode` });
    const docResult = ctx.outputMaybe("docReview", { nodeId: "verify-doc-extra" }) ?? ctx.outputMaybe("docReview", { nodeId: "verify-doc" });
    children.push(
      <Task id="summary" output={outputs.summary} retries={1} bind={gate0Proof}>
        {() => {
          const reportDir = path.join(os.tmpdir(), "se-pipeline", "reports", ctx.runId.slice(0, 8));
          fs.mkdirSync(reportDir, { recursive: true });
          if (workReport) fs.writeFileSync(path.join(reportDir, "work.envelope.json"), workReport.report);
          if (codeReport) fs.writeFileSync(path.join(reportDir, "verify-code.report.json"), codeReport.report);
          if (codeClaudeReport) fs.writeFileSync(path.join(reportDir, "verify-code.claude.report.json"), codeClaudeReport.report);
          if (codeOpencodeReport) fs.writeFileSync(path.join(reportDir, "verify-code.opencode.report.json"), codeOpencodeReport.report);
          if (docResult) fs.writeFileSync(path.join(reportDir, "verify-doc.result.json"), JSON.stringify(docResult, null, 2));
          const headSha = gitHead(staged.worktreePath);
          // Read cost BEFORE any irreversible cleanup: a sqlite/JSON failure in
          // readRunUsage must not abort the summary after the lock and worktree
          // are already gone (they would then never be released/removed).
          const usage = aggregateUsage(readRunUsage(ctx.runId));
          if (t === "green") {
            cleanupSnapshot(repoDir, staged.worktreePath);
          }
          releaseRepoLock(repoDir, ctx.runId);
          return {
            verdict: t,
            planPath: gate0.planPath,
            planHash: gate0.planHash,
            branch: staged.branch,
            baseSha: staged.baseSha,
            headSha,
            stages: JSON.stringify(stages),
            notes: notes.join(" | "),
            reportDir,
            totalTokens: usage.totalTokens,
            estCostUsd: Math.round(usage.totalEstUsd * 10000) / 10000,
            stageUsage: JSON.stringify(usage.stages),
          };
        }}
      </Task>,
    );
  }

  return (
    <Workflow name="se-pipeline">
      <Sequence>{children}</Sequence>
    </Workflow>
  );
});
