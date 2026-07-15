/** @jsxImportSource smithers-orchestrator */
// THROWAWAY U1 spike (plan 2026-07-14-001-feat-smithers-pipeline-plan.md).
// Verifies 0.27.0 primitives before building se-pipeline.tsx:
//   scenario=gates      — (а) red gate → Approval → approve → resume,
//                         (б) kill -9 after a real commit → resume must not duplicate it,
//                         (в) kill during Approval pause → resume returns to waiting-approval,
//                         (ж) approve after hard stage fail = one extra attempt; second pause abort-only.
//   scenario=subflow    — (г) <Subflow childRun> around se-doc-review.tsx (smoke) + module-level env caveat.
//   scenario=cework     — (д) headless `ce-work mode:return-to-caller` on the fixture repo; capture envelope.
//   scenario=streamjson — (KTD9) subagent-heavy capture WITHOUT outputFormat:"json" override.
// Run from the smithers dir:
//   ./node_modules/.bin/smithers up workflows/spike-pipeline.tsx --input '{"scenario":"gates",...}'
import { createSmithers, ClaudeCodeAgent, Subflow, TryCatchFinally, approvalDecisionSchema } from "smithers-orchestrator";
import { z } from "zod/v4";
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import seDocReview from "./se-doc-review.tsx";

const inputSchema = z.object({
  scenario: z.enum(["gates", "subflow", "cework", "streamjson"]),
  fixtureRepo: z.string().default("").describe("Abs path to a throwaway git repo (gates: real commits; cework/streamjson: agent cwd)."),
  planPath: z.string().default("").describe("cework: abs path to the fixture plan."),
  docPath: z.string().default("").describe("subflow: abs path of the doc passed to se-doc-review smoke."),
  flagFile: z.string().default("").describe("gates: while this file exists the flaky stage throws."),
  commitSleepMs: z.number().default(0).describe("gates: sleep INSIDE the commit task after git commit (kill window → expect duplicate on resume)."),
  slowMs: z.number().default(0).describe("gates: slow stage duration (kill window AFTER commit persisted → expect no duplicate)."),
});

const subflowResultSchema = z.object({
  stageDir: z.string(),
  pluginVersion: z.string(),
  claudeStatus: z.enum(["ok", "failed"]),
  opencodeStatus: z.enum(["ok", "failed"]),
  claudeEnvelopePath: z.string().optional(),
  opencodeEnvelopePath: z.string().optional(),
});

const { Workflow, Task, Sequence, Branch, Approval, smithers, outputs } = createSmithers({
  input: inputSchema,
  s1: z.object({ value: z.string() }),
  commit: z.object({ sha: z.string() }),
  slow: z.object({ done: z.boolean() }),
  flaky: z.object({ ok: z.boolean() }),
  failed: z.object({ stage: z.string() }),
  approval: approvalDecisionSchema,
  subflowResult: subflowResultSchema,
  report: z.object({ report: z.string() }),
  final: z.object({ message: z.string() }),
});

const reportJsonSchema = JSON.stringify({
  type: "object",
  properties: { report: { type: "string" } },
  required: ["report"],
});

function git(cwd: string, ...args: string[]): string {
  return execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8" }).trim();
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export default smithers((ctx) => {
  const input = ctx.input;

  if (input.scenario === "gates") {
    const flakyOk = ctx.outputMaybe("flaky", { nodeId: "flaky" });
    const flakyFailed = ctx.outputMaybe("failed", { nodeId: "flaky-failed" });
    const gate1 = ctx.outputMaybe("approval", { nodeId: "gate1" });
    const extraOk = ctx.outputMaybe("flaky", { nodeId: "flaky-extra" });
    const extraFailed = ctx.outputMaybe("failed", { nodeId: "flaky-extra-failed" });

    const flakyBody = () => {
      if (input.flagFile && fs.existsSync(input.flagFile)) {
        throw new Error("flaky stage failed (flag file present)");
      }
      return { ok: true };
    };

    return (
      <Workflow name="spike-gates">
        <Sequence>
          <Task id="s1" output={outputs.s1}>
            {() => ({ value: "artificial-1" })}
          </Task>
          <Task id="commit" output={outputs.commit}>
            {async () => {
              fs.appendFileSync(path.join(input.fixtureRepo, "log.txt"), `stage-commit at ${new Date().toISOString()}\n`);
              git(input.fixtureRepo, "add", "-A");
              git(input.fixtureRepo, "commit", "-m", "spike: stage commit");
              const sha = git(input.fixtureRepo, "rev-parse", "HEAD");
              if (input.commitSleepMs > 0) await sleep(input.commitSleepMs);
              return { sha };
            }}
          </Task>
          <Task id="slow" output={outputs.slow}>
            {async () => {
              if (input.slowMs > 0) await sleep(input.slowMs);
              return { done: true };
            }}
          </Task>
          <TryCatchFinally
            id="guard-flaky"
            try={
              <Task id="flaky" output={outputs.flaky} retries={1}>
                {flakyBody}
              </Task>
            }
            catch={
              <Task id="flaky-failed" output={outputs.failed}>
                {() => ({ stage: "flaky" })}
              </Task>
            }
          />
          <Branch
            if={!!flakyFailed}
            then={
              <Approval
                id="gate1"
                output={outputs.approval}
                request={{ title: "flaky failed after retries — approve ONE extra attempt?", summary: "deny aborts the run" }}
                onDeny="fail"
              />
            }
          />
          {gate1?.approved ? (
            <TryCatchFinally
              id="guard-flaky-extra"
              try={
                <Task id="flaky-extra" output={outputs.flaky}>
                  {flakyBody}
                </Task>
              }
              catch={
                <Task id="flaky-extra-failed" output={outputs.failed}>
                  {() => ({ stage: "flaky-extra" })}
                </Task>
              }
            />
          ) : null}
          <Branch
            if={!!extraFailed}
            then={
              <Approval
                id="gate2"
                output={outputs.approval}
                request={{ title: "extra attempt failed — abort only", summary: "deny to abort (approve is a no-op for the spike)" }}
                onDeny="fail"
              />
            }
          />
          {(flakyOk ?? extraOk) ? (
            <Task id="final" output={outputs.final}>
              {() => ({ message: `gates done; head=${git(input.fixtureRepo, "rev-parse", "HEAD")}` })}
            </Task>
          ) : null}
        </Sequence>
      </Workflow>
    );
  }

  if (input.scenario === "subflow") {
    const sub = ctx.outputMaybe("subflowResult", { nodeId: "doc-review" });
    return (
      <Workflow name="spike-subflow">
        <Sequence>
          <Subflow
            id="doc-review"
            workflow={seDocReview}
            input={{ docPath: input.docPath, smoke: true }}
            output={outputs.subflowResult}
            timeoutMs={10 * 60_000}
          />
          {sub ? (
            <Task id="final" output={outputs.final}>
              {() => ({
                message: `subflow ok: claude=${sub.claudeStatus} opencode=${sub.opencodeStatus} stageDir=${sub.stageDir} parentEnv=${process.env.DOC_REVIEW_REPO ?? "<unset>"}`,
              })}
            </Task>
          ) : null}
        </Sequence>
      </Workflow>
    );
  }

  const agent = new ClaudeCodeAgent({
    cwd: input.fixtureRepo,
    permissionMode: "bypassPermissions",
    dangerouslySkipPermissions: true,
    timeoutMs: 15 * 60_000,
    maxBudgetUsd: 5,
    jsonSchema: reportJsonSchema,
    // KTD9 probe: NO outputFormat override — default stream-json.
  });

  if (input.scenario === "cework") {
    const rep = ctx.outputMaybe("report", { nodeId: "cework" });
    return (
      <Workflow name="spike-cework">
        <Sequence>
          <Task id="cework" output={outputs.report} agent={agent}>
            {`[spike-cework]

Invoke the skill compound-engineering:ce-work with args "mode:return-to-caller ${input.planPath}".

Context: you are in a throwaway fixture repo, already on branch feat/slugify — continue on this branch, do NOT ask about branches, do NOT create worktrees. Fully headless: never ask questions; make every decision yourself.

You are EXPLICITLY REQUESTED to commit: stage and commit the implemented work on the current branch with a conventional message (this instruction is the explicit commit request; it overrides any default no-commit policy). Do not push.

Your FINAL message must be EXACTLY one JSON object and nothing else: {"report": "<the skill's return-to-caller envelope (status, plan_path, changed_files, u_ids_attempted, u_ids_completed, verification_results, verification_evidence, blockers, behavior_change, standalone_shipping_skipped) EXTENDED with one additional required field final_commit_sha — the output of git rev-parse HEAD after your last commit — serialized as a string>"}.`}
          </Task>
          {rep ? (
            <Task id="final" output={outputs.final}>
              {() => {
                const out = path.join(input.fixtureRepo, "..", "cework-envelope.json");
                fs.writeFileSync(out, rep.report);
                return { message: `envelope saved to ${out}; head=${git(input.fixtureRepo, "rev-parse", "HEAD")}` };
              }}
            </Task>
          ) : null}
        </Sequence>
      </Workflow>
    );
  }

  // scenario === "streamjson"
  const rep = ctx.outputMaybe("report", { nodeId: "probe" });
  return (
    <Workflow name="spike-streamjson">
      <Sequence>
        <Task id="probe" output={outputs.report} agent={agent}>
          {`[spike-streamjson] Subagent-heavy capture probe. Dispatch TWO parallel subagents via your Agent/Task tool: one summarizes package.json in one sentence, the other summarizes README.md (or any file) in one sentence. Wait for both. Then your FINAL message must be EXACTLY one JSON object: {"report": "<subagent A summary> | <subagent B summary>"}.`}
        </Task>
        {rep ? (
          <Task id="final" output={outputs.final}>
            {() => ({ message: `probe captured ${rep.report.length} chars` })}
          </Task>
        ) : null}
      </Sequence>
    </Workflow>
  );
});
