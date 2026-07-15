/** @jsxImportSource smithers-orchestrator */
// se-pipeline U3 skeleton: durable spine verify-doc → work → verify-code with
// gate-0 plan validation (KTD7), code gates between stages (KTD3), Approval
// pauses on red, and per-gate approve semantics proven in the U1 spike:
// verify gates get ONE extra attempt as a fresh node, the code-review gate
// approve = waive, a second red pause stops the run with a report (R3).
// Stages are STUBS until U4; force reds via input.stubFail (+ flagFile to make
// the failure clear before resume, as in the spike).
//   ./node_modules/.bin/smithers up workflows/se-pipeline.tsx \
//     --input '{"planPath":"/abs/plan.md","until":"branch"}'
import { createSmithers, TryCatchFinally, approvalDecisionSchema } from "smithers-orchestrator";
import { z } from "zod/v4";
import * as fs from "node:fs";
import { codeReviewGate, docReviewGate, planGate, workGate, type GateResult } from "./lib/gates.ts";

const inputSchema = z.object({
  planPath: z.string().describe("Absolute path to the implementation-ready ce-unified-plan/v1 plan."),
  until: z.enum(["branch", "pr"]).default("branch").describe("Run depth (R6); pr is a hard refusal in the MVP."),
  stubFail: z.enum(["none", "verify-doc", "work", "verify-code"]).default("none").describe("U3 stubs only: force this stage's gate red."),
  flagFile: z.string().default("").describe("U3 stubs only: with stubFail, the stage fails only while this file exists."),
  stubSleepMs: z.number().default(0).describe("U3 stubs only: sleep inside the work stub (kill window for AE3 demos)."),
});

const gateVerdictSchema = z.object({
  stage: z.string(),
  state: z.enum(["green", "failed", "degraded"]),
  reasons: z.string(),
  p1Count: z.number().optional(),
});

const { Workflow, Task, Sequence, Approval, smithers, outputs } = createSmithers({
  input: inputSchema,
  gate0: z.object({ planHash: z.string(), planPath: z.string(), until: z.string() }),
  stageOut: z.object({ stage: z.string(), raw: z.string() }),
  failedMarker: z.object({ stage: z.string() }),
  gateVerdict: gateVerdictSchema,
  approval: approvalDecisionSchema,
  summary: z.object({ verdict: z.string(), planHash: z.string(), stages: z.string(), notes: z.string() }),
});

const STUB_SHA = "f".repeat(40);

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
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

  const gate0 = ctx.outputMaybe("gate0", { nodeId: "gate0" });

  // ctx.input arrives WITHOUT Zod defaults applied (the donors coalesce
  // `ctx.input.smoke ?? false` for the same reason) — guard every optional.
  const until = input.until ?? "branch";
  const stubFail = input.stubFail ?? "none";
  const flagFile = input.flagFile ?? "";
  const stubSleepMs = input.stubSleepMs ?? 0;

  const failNow = (stage: string): boolean =>
    stubFail === stage && (flagFile === "" || fs.existsSync(flagFile));

  const stubBodies: Record<string, () => Promise<{ stage: string; raw: string }> | { stage: string; raw: string }> = {
    "verify-doc": () => ({
      stage: "verify-doc",
      raw: JSON.stringify(
        failNow("verify-doc")
          ? { claudeStatus: "failed", opencodeStatus: "failed" }
          : { claudeStatus: "ok", opencodeStatus: "ok" },
      ),
    }),
    work: async () => {
      if (stubSleepMs > 0) await sleep(stubSleepMs);
      return {
        stage: "work",
        raw: JSON.stringify({
          status: "complete",
          changed_files: ["stub.ts"],
          verification_evidence: failNow("work") ? [] : [{ unit: "stub", behavior_changed: true }],
          final_commit_sha: STUB_SHA,
        }),
      };
    },
    "verify-code": () => ({
      stage: "verify-code",
      raw: JSON.stringify({
        status: "complete",
        findings: failNow("verify-code")
          ? [{ severity: "P0", title: "stub planted P0" }]
          : [{ severity: "P1", title: "stub P1" }],
      }),
    }),
  };

  const gateFns: Record<string, (raw: string | undefined) => GateResult> = {
    "verify-doc": (raw) => docReviewGate(raw === undefined ? undefined : JSON.parse(raw)),
    work: (raw) => workGate({ raw, headSha: STUB_SHA, validateExitCode: raw === undefined ? null : 0 }),
    "verify-code": (raw) => codeReviewGate({ raw }),
  };

  const toVerdict = (stage: string, r: GateResult): z.infer<typeof gateVerdictSchema> => ({
    stage,
    state: r.state,
    reasons: r.reasons.join("; "),
    ...(r.p1Count === undefined ? {} : { p1Count: r.p1Count }),
  });

  // One stage = attempt → gate → (red) Approval → extra attempt as a FRESH
  // node (U1 verdict: approve re-runs nothing by itself) → gate → (red again)
  // abort-only Approval. waiveOnApprove switches the first Approval to the
  // G3 semantics: approve = continue green, no extra attempt (KTD3).
  function stageBlock(name: string, opts: { retries: number; waiveOnApprove: boolean }): StageBlock {
    const nodes: unknown[] = [];
    const out1 = ctx.outputMaybe("stageOut", { nodeId: name });
    const crash1 = ctx.outputMaybe("failedMarker", { nodeId: `${name}-crashed` });
    const v1 = ctx.outputMaybe("gateVerdict", { nodeId: `gate-${name}` });
    const ap1 = ctx.outputMaybe("approval", { nodeId: `approve-${name}-1` });
    const out2 = ctx.outputMaybe("stageOut", { nodeId: `${name}-extra` });
    const crash2 = ctx.outputMaybe("failedMarker", { nodeId: `${name}-extra-crashed` });
    const v2 = ctx.outputMaybe("gateVerdict", { nodeId: `gate-${name}-extra` });
    const ap2 = ctx.outputMaybe("approval", { nodeId: `approve-${name}-2` });

    nodes.push(
      <TryCatchFinally
        id={`guard-${name}`}
        try={
          <Task id={name} output={outputs.stageOut} retries={opts.retries}>
            {stubBodies[name]}
          </Task>
        }
        catch={
          <Task id={`${name}-crashed`} output={outputs.failedMarker}>
            {() => ({ stage: name })}
          </Task>
        }
      />,
    );
    if (out1 || crash1) {
      nodes.push(
        <Task id={`gate-${name}`} output={outputs.gateVerdict}>
          {() => toVerdict(name, gateFns[name](out1?.raw))}
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

    nodes.push(
      <TryCatchFinally
        id={`guard-${name}-extra`}
        try={
          <Task id={`${name}-extra`} output={outputs.stageOut}>
            {stubBodies[name]}
          </Task>
        }
        catch={
          <Task id={`${name}-extra-crashed`} output={outputs.failedMarker}>
            {() => ({ stage: name })}
          </Task>
        }
      />,
    );
    if (out2 || crash2) {
      nodes.push(
        <Task id={`gate-${name}-extra`} output={outputs.gateVerdict}>
          {() => toVerdict(name, gateFns[name](out2?.raw))}
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
        return { planHash: result.hash, planPath: input.planPath, until };
      }}
    </Task>,
  ];

  const notes: string[] = [];
  let terminal: string | undefined;

  if (gate0) {
    const doc = stageBlock("verify-doc", { retries: 1, waiveOnApprove: false });
    children.push(...(doc.nodes as never[]));
    if (doc.status === "stopped") terminal = "stopped-after-second-failure:verify-doc";
    if (doc.status === "green") {
      if (doc.verdict?.reasons) notes.push(`verify-doc: ${doc.verdict.reasons}`);
      // KTD5: a failed work stage goes straight to Approval — no blind retry.
      const work = stageBlock("work", { retries: 0, waiveOnApprove: false });
      children.push(...(work.nodes as never[]));
      if (work.status === "stopped") terminal = "stopped-after-second-failure:work";
      if (work.status === "green") {
        const code = stageBlock("verify-code", { retries: 1, waiveOnApprove: true });
        children.push(...(code.nodes as never[]));
        if (code.status === "stopped") terminal = "stopped-after-second-failure:verify-code";
        if (code.status === "green") {
          if (code.waived) notes.push(`verify-code: P0 waived by operator — ${code.verdict?.reasons ?? ""}`);
          terminal = "green";
        }
      }
    }
  }

  if (terminal) {
    const t = terminal;
    const stages: Record<string, unknown> = {};
    for (const stage of ["verify-doc", "work", "verify-code"]) {
      const extra = ctx.outputMaybe("gateVerdict", { nodeId: `gate-${stage}-extra` });
      const first = ctx.outputMaybe("gateVerdict", { nodeId: `gate-${stage}` });
      stages[stage] = extra ?? first ?? null;
    }
    children.push(
      <Task id="summary" output={outputs.summary}>
        {() => ({
          verdict: t,
          planHash: gate0?.planHash ?? "",
          stages: JSON.stringify(stages),
          notes: notes.join(" | "),
        })}
      </Task>,
    );
  }

  return (
    <Workflow name="se-pipeline">
      <Sequence>{children}</Sequence>
    </Workflow>
  );
});
