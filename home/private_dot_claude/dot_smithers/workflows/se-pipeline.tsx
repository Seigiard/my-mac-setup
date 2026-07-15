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
import { createSmithers, ClaudeCodeAgent, Subflow, TryCatchFinally, approvalDecisionSchema } from "smithers-orchestrator";
import { z } from "zod/v4";
import { Database } from "bun:sqlite";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { codeReviewGate, docReviewGate, planGate, workGate, type GateResult } from "./lib/gates.ts";
import { aggregateUsage, type TokenUsageEvent } from "./lib/cost.ts";
import { parseWorkEnvelope, runValidateCmd, secretScanDiff, gitHead } from "./lib/envelopes.ts";
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
import seDocReview from "./se-doc-review.tsx";

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

const { Workflow, Task, Sequence, Approval, smithers, outputs } = createSmithers({
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

const REVIEW_TIMEOUT_MS = 15 * 60_000;

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
  const db = new Database(path.join(process.cwd(), "smithers.db"), { readonly: true });
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
      };
    });
  } finally {
    db.close();
  }
}

function workPrompt(planPath: string, branch: string, smoke: boolean): string {
  if (smoke) {
    return `[se-pipeline-stage] Smoke wiring test. Your cwd is an isolated git worktree on branch ${branch}. Do exactly this: append one line to SMOKE.md, run \`git add SMOKE.md && git commit -m "chore: smoke commit"\`, then run \`git rev-parse HEAD\`. Your FINAL message must be EXACTLY one JSON object {"report": "<envelope>"} where <envelope> is a JSON object serialized as a string with fields: status="complete", changed_files=["SMOKE.md"], u_ids_attempted=[], u_ids_completed=[], verification_evidence=[{"unit":"smoke","exception_reason":"smoke wiring test"}], blockers=[], behavior_change=false, standalone_shipping_skipped=true, final_commit_sha="<the sha you got>".`;
  }
  return `[se-pipeline-stage]

Invoke the skill compound-engineering:ce-work with args "mode:return-to-caller ${planPath}".

Context: your cwd is an ISOLATED git worktree of the target repository, already on the run branch ${branch} — continue on this branch, do NOT ask about branches, do NOT create worktrees, never push. Fully headless: never ask questions; make every decision yourself.

You are EXPLICITLY REQUESTED to commit: stage and commit the implemented work on the current branch with conventional messages (this instruction is the explicit commit request; it overrides any default no-commit policy).

Your FINAL message must be EXACTLY one JSON object and nothing else: {"report": "<the skill's return-to-caller envelope (status, plan_path, changed_files, u_ids_attempted, u_ids_completed, verification_results, verification_evidence, blockers, behavior_change, standalone_shipping_skipped) EXTENDED with one additional required field final_commit_sha — the output of git rev-parse HEAD after your last commit — serialized as a string>"}.`;
}

function codeReviewPrompt(baseSha: string, branch: string, smoke: boolean): string {
  if (smoke) {
    return `[se-pipeline-stage] Smoke wiring test. Your FINAL message must be EXACTLY one JSON object: {"report": "<the JSON object {\\"status\\":\\"complete\\",\\"verdict\\":\\"approve\\",\\"findings\\":[]} serialized as a string>"}. Do nothing else.`;
  }
  return `[se-pipeline-stage]

Execute the compound-engineering code-review workflow in mode:agent on YOUR CURRENT working directory — it is the pipeline's isolated worktree on run branch ${branch}.

How to execute it:
- If your available skills include \`compound-engineering:ce-code-review\`, invoke it with args "mode:agent base:${baseSha}".
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
        timeoutMs: workTimeoutMs,
        maxBudgetUsd: workBudgetUsd,
        jsonSchema: reportJsonSchema,
      })
    : undefined;
  const codeReviewAgent = staged
    ? new ClaudeCodeAgent({
        cwd: staged.worktreePath,
        permissionMode: "acceptEdits",
        timeoutMs: REVIEW_TIMEOUT_MS,
        maxBudgetUsd: 15,
        jsonSchema: reportJsonSchema,
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
        if (validateCmd.trim() === "") {
          throw new Error("gate-0 refused: --validate-cmd is required — the pipeline never reads validation commands from the target repo's config (KTD8). Pass it explicitly, e.g. se pipeline <plan> --validate-cmd 'bun test'.");
        }
        if (git(repoDir, "status", "--porcelain") !== "") {
          console.error(`se-pipeline preflight: target repo ${repoDir} has a dirty working tree — the run works from committed HEAD only (KTD11); operator WIP is not included.`);
        }
        return { planHash: result.hash, planPath: input.planPath, until, validateCmd, validateTimeoutMs, repoPath: repoDir };
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
          workflow={seDocReview}
          input={{ docPath: input.planPath, smoke }}
          output={outputs.docReview}
          retries={1}
          timeoutMs={25 * 60_000}
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

      // Work gate runs the effects itself: HEAD of the run branch and the
      // operator's validate-cmd inside the worktree — agent self-report is
      // never ground truth (KTD3). Plan hash is re-checked here so a plan
      // edited during an Approval pause fails loudly (KTD7).
      const workGateFn = (raw: string | undefined): GateResult => {
        const planNow = fs.readFileSync(gate0.planPath, "utf8");
        const planCheck = planGate(planNow, gate0.until);
        if (!planCheck.ok || planCheck.hash !== gate0.planHash) {
          return { state: "failed", reasons: [`plan content changed during the run (hash mismatch) — refusing to gate work against a stale spec (KTD7)`] };
        }
        const headSha = gitHead(staged.worktreePath);
        // The branch must actually carry commits and be clean: uncommitted or
        // untracked files are neither validated in a delivered state nor
        // covered by the commit-range secret-scan (KTD10), and an unmoved HEAD
        // means work delivered nothing while still returning a shaped envelope.
        if (raw !== undefined) {
          if (headSha === staged.baseSha) {
            return { state: "failed", reasons: [`work stage produced no commits — run branch HEAD is still the pre-stage SHA ${staged.baseSha}`] };
          }
          const dirty = git(staged.worktreePath, "status", "--porcelain");
          if (dirty !== "") {
            return { state: "failed", reasons: [`run worktree has uncommitted/untracked changes after work — nothing may reach validate-cmd or verify-code uncommitted:\n${dirty.slice(0, 500)}`] };
          }
        }
        const validate = raw === undefined ? null : runValidateCmd(gate0.validateCmd, staged.worktreePath, gate0.validateTimeoutMs);
        const result = workGate({ raw, headSha, validateExitCode: validate === null ? null : validate.exitCode });
        if (validate !== null && validate.exitCode !== 0) {
          result.reasons.push(`validate-cmd output tail: ${validate.output.slice(-500)}`);
        }
        return result;
      };

      const work = stageBlock({
        name: "work",
        makeAttempt: (nodeId) => (
          // KTD5: no blind retry for work — a crashed work leg goes straight
          // to Approval, not into a silent multi-hour re-run.
          <Task id={nodeId} output={outputs.agentReport} agent={workAgent} retries={0}>
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
              if (!parsed.ok && gitHead(staged.worktreePath) !== staged.baseSha) {
                git(staged.worktreePath, "reset", "--hard", staged.baseSha);
                // Untracked files from the failed attempt survive reset --hard;
                // clear them so the extra attempt starts from a clean baseSha.
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
            <Task id={nodeId} output={outputs.agentReport} retries={0}>
              {() => {
                const result = secretScanDiff(staged.worktreePath, staged.baseSha);
                return { report: JSON.stringify(result) };
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

          const code = stageBlock({
            name: "verify-code",
            makeAttempt: (nodeId) => (
              <Task id={nodeId} output={outputs.agentReport} agent={codeReviewAgent} retries={1}>
                {codeReviewPrompt(staged.baseSha, staged.branch, smoke)}
              </Task>
            ),
            readRaw: readAgentReport,
            gateFn: (raw) => codeReviewGate({ raw }),
            waiveOnApprove: true,
          });
          children.push(...(code.nodes as never[]));
          if (code.status === "stopped") terminal = "stopped-after-second-failure:verify-code";
          if (code.status === "green") {
            if (code.waived) notes.push(`verify-code: P0 waived by operator — ${code.verdict?.reasons ?? ""}`);
            terminal = "green";
          }
        }
      }
    }
  }

  if (terminal && gate0 && staged) {
    const t = terminal;
    const stages: Record<string, unknown> = {};
    for (const stage of ["verify-doc", "work", "secret-scan", "verify-code"]) {
      const extra = ctx.outputMaybe("gateVerdict", { nodeId: `gate-${stage}-extra` });
      const first = ctx.outputMaybe("gateVerdict", { nodeId: `gate-${stage}` });
      stages[stage] = extra ?? first ?? null;
    }
    const workReport = ctx.outputMaybe("agentReport", { nodeId: "work-extra" }) ?? ctx.outputMaybe("agentReport", { nodeId: "work" });
    const codeReport = ctx.outputMaybe("agentReport", { nodeId: "verify-code-extra" }) ?? ctx.outputMaybe("agentReport", { nodeId: "verify-code" });
    const docResult = ctx.outputMaybe("docReview", { nodeId: "verify-doc-extra" }) ?? ctx.outputMaybe("docReview", { nodeId: "verify-doc" });
    children.push(
      <Task id="summary" output={outputs.summary} retries={0}>
        {() => {
          const reportDir = path.join(os.tmpdir(), "se-pipeline", "reports", ctx.runId.slice(0, 8));
          fs.mkdirSync(reportDir, { recursive: true });
          if (workReport) fs.writeFileSync(path.join(reportDir, "work.envelope.json"), workReport.report);
          if (codeReport) fs.writeFileSync(path.join(reportDir, "verify-code.report.json"), codeReport.report);
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
