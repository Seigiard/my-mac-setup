/** @jsxImportSource smithers-orchestrator */
// se-simplify: the shared simplify stage — standalone skill AND se-pipeline
// Subflow. Right-sizing gate → freeze snapshot → Parallel(claude, opencode)
// REPORT-ONLY ce-simplify-code reviewer legs → mergeSimplifyLegs (consensus/
// unique; contradictions excluded) → ONE apply leg (Sonnet, re-locate by
// content) → verify via validate-cmd (revert-whole-apply + degrade on failure,
// never a silent success).
//
// repoPath is an EXPLICIT workflow input (KTD-G): the pipeline passes the run
// worktree (staged.worktreePath); standalone falls back to SIMPLIFY_REPO env.
// There is NO module-scope `process.env ?? process.cwd()` read — that would
// make the apply leg mutate the operator's live launch checkout mid-run.
//
// Staging lives under /tmp/ce-simplify — opencode reads it via the
// permission.external_directory allow in ~/.config/opencode/opencode.json.
// Standalone:
//   cd ~/.claude/.smithers && ./node_modules/.bin/smithers up workflows/se-simplify.tsx \
//     --input '{"repoPath":"/abs/repo","validateCmd":"bun test"}'
import { createSmithers, TryCatchFinally } from "smithers-orchestrator";
import { z } from "zod/v4";
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import {
  AGENT_PROFILES,
  makeClaudeReviewAgent,
  makeOpencodeReviewAgent,
  makeSimplifyApplyAgent,
  makeSimplifyClassifierAgent,
} from "./lib/agents.ts";
import {
  consultHardRules,
  skillFallbackLine,
  SIMPLIFY_REPORT_NO_CHANGES_RULES,
  SIMPLIFY_REPORT_EXTRA_RULES,
  SIMPLIFY_APPLY_SAFETY_RULES,
} from "./lib/consult-prompt.ts";
import { reviewLegSchema } from "./lib/review-schema.ts";
import { mergeSimplifyLegs, type ReviewLeg, type SimplifyMergeResult } from "./lib/review-merge.ts";
import { parseNumstat, shouldRunSimplify } from "./lib/stage-gate.ts";
import { runValidateCmd } from "./lib/envelopes.ts";
import { enforcePreExternalGate, preExternalRepoGate, preExternalTreeGate } from "./lib/pre-external-gate.ts";
import { stashCreateSafe } from "./lib/staging.ts";
import { stageCompoundSkill } from "./lib/compound-skill.ts";

const STAGE_ROOT = "/tmp/ce-simplify";
const APPLY_TIMEOUT_MS = 20 * 60_000;
const APPLY_BUDGET_USD = 15;

const inputSchema = z.object({
  repoPath: z
    .string()
    .default("")
    .describe("Absolute path to the repo to simplify. Pipeline passes the run worktree (staged.worktreePath); standalone falls back to SIMPLIFY_REPO env."),
  validateCmd: z
    .string()
    .default("")
    .describe("Behavior-preservation command run after apply. REQUIRED to apply — empty refuses to apply (standalone has no gate-0 default)."),
  validateTimeoutMs: z.number().default(10 * 60_000),
  baseSha: z
    .string()
    .default("")
    .describe("Base commit for the work diff (pipeline passes staged.baseSha). Empty = auto-detect merge-base with the repo's base branch."),
  target: z.string().default("").describe("Optional scope tokens forwarded to the ce-simplify-code reviewers."),
  useClassifier: z.boolean().default(true).describe("On an inconclusive deterministic gate, consult the cheap Haiku classifier (skip-when-unsure). Off = skip when inconclusive."),
  preScanned: z
    .boolean()
    .default(false)
    .describe("The CALLER already applied the pre-external secret boundary to this range (se-pipeline does, KTD10 — including its operator waiver). True skips the standalone gate so a waived pipeline run is not blocked twice; standalone leaves it false."),
  smoke: z.boolean().default(false).describe("Wiring test: synthetic stage + trivial leg prompts, no real ce-simplify-code, no git."),
});

const gateSchema = z.object({
  run: z.boolean(),
  reason: z.string(),
  inconclusive: z.boolean(),
  source: z.string(),
});

const classifierSchema = z.object({ run: z.boolean(), reason: z.string().default("") });

const stageSchema = z.object({
  stageDir: z.string(),
  skillDir: z.string(),
  skillRevision: z.string(),
  snapshotDir: z.string(),
  snapshotSha: z.string(),
  consultTarget: z.string(),
});

const failedSchema = z.object({ agent: z.string() });
const synthSchema = z.object({ merged: z.string() });
const preApplySchema = z.object({ head: z.string(), stashRef: z.string(), dirtyBefore: z.string() });
const applyReportSchema = z.object({ report: z.string() });
const verifySchema = z.object({
  status: z.enum(["ok", "degraded"]),
  appliedEdits: z.boolean(),
  validateExitCode: z.number().nullable(),
  reverted: z.boolean(),
  reason: z.string(),
});

const outputSchema = z.object({
  status: z.enum(["ok", "skipped", "degraded"]),
  reason: z.string(),
  stageDir: z.string().nullish(),
  consultTarget: z.string().nullish(),
  claudeStatus: z.enum(["ok", "failed", "n/a"]),
  opencodeStatus: z.enum(["ok", "failed", "n/a"]),
  appliedEdits: z.boolean(),
  appliedCount: z.number(),
  contradictionCount: z.number(),
  validateExitCode: z.number().nullable(),
  reverted: z.boolean(),
  reportPath: z.string().nullish(),
});

const { Workflow, Task, Sequence, Parallel, smithers, outputs } = createSmithers({
  input: inputSchema,
  gate: gateSchema,
  classifier: classifierSchema,
  stage: stageSchema,
  review: reviewLegSchema,
  failed: failedSchema,
  synth: synthSchema,
  preApply: preApplySchema,
  applyReport: applyReportSchema,
  verify: verifySchema,
  output: outputSchema,
});

function git(cwd: string, ...args: string[]): string {
  return execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8" }).trim();
}

function detectBaseRef(repoPath: string): string {
  try {
    const head = git(repoPath, "symbolic-ref", "refs/remotes/origin/HEAD");
    return head.replace("refs/remotes/", "");
  } catch {
    for (const ref of ["origin/main", "main", "master"]) {
      try {
        git(repoPath, "rev-parse", "--verify", ref);
        return ref;
      } catch {}
    }
    throw new Error("se-simplify: cannot detect a base branch (origin/HEAD, origin/main, main, master all missing).");
  }
}

// The work diff the gate + the reviewers scope on: baseSha..HEAD when an
// explicit base is passed (pipeline), else merge-base with the detected base.
function resolveBase(repoPath: string, baseSha: string): string {
  if (baseSha.trim() !== "") return baseSha.trim();
  const head = git(repoPath, "rev-parse", "HEAD");
  return git(repoPath, "merge-base", head, detectBaseRef(repoPath));
}

// Freeze repoPath so the two report legs analyze a stable snapshot while nothing
// (a concurrent human, the later apply leg) moves it. `git stash create`
// captures dirty tracked state as a commit without touching the working tree;
// the detached worktree checks it out under /tmp/ce-simplify where opencode is
// allowed to read.
function stage(
  repoPath: string,
  target: string,
  baseSha: string,
  smoke: boolean,
  preScanned: boolean,
): z.infer<typeof stageSchema> {
  const stageDir = path.join(STAGE_ROOT, `run-${Date.now()}`);
  if (smoke) {
    const snapshotDir = path.join(stageDir, "repo");
    fs.mkdirSync(snapshotDir, { recursive: true });
    return { stageDir, skillDir: "", skillRevision: "smoke", snapshotDir, snapshotSha: "SMOKE", consultTarget: "SMOKE" };
  }

  // Secret-gate the snapshot BEFORE anything is staged or dispatched, unless the
  // caller already scanned this range (preScanned — the pipeline's shared KTD10
  // boundary, which the parent plan's R10 says not to reinvent). A refusal
  // throws here, so no snapshot worktree and no readable /tmp copy is created.
  const snapshotSha = stashCreateSafe(repoPath) || git(repoPath, "rev-parse", "HEAD");
  const base = resolveBase(repoPath, baseSha);
  if (!preScanned) {
    enforcePreExternalGate(preExternalRepoGate({ repo: repoPath, baseSha: base, head: snapshotSha, label: "se-simplify" }));
    // Tier 2: the legs read the WHOLE snapshot tree, not just the range above —
    // including files committed on the base branch before this run started.
    enforcePreExternalGate(preExternalTreeGate({ repo: repoPath, head: snapshotSha, label: "se-simplify" }));
  }

  const skillDir = path.join(stageDir, "skill");
  fs.mkdirSync(stageDir, { recursive: true });
  const skill = stageCompoundSkill("ce-simplify-code", skillDir);

  const snapshotDir = path.join(stageDir, "repo");
  git(repoPath, "worktree", "add", "--detach", snapshotDir, snapshotSha);

  const consultTarget = target.trim() || `base:${base}`;
  return { stageDir, skillDir, skillRevision: skill.skillRevision, snapshotDir, snapshotSha, consultTarget };
}

function cleanupSnapshot(repoPath: string, snapshotDir: string): void {
  if (!repoPath || !snapshotDir) return;
  try {
    git(repoPath, "worktree", "remove", "--force", snapshotDir);
  } catch {
    try {
      git(repoPath, "worktree", "prune");
    } catch {}
  }
}

function classifierPrompt(consultTarget: string, reason: string): string {
  return `[ce-simplify-external-consult] Right-sizing classifier. A deterministic gate found this work diff BORDERLINE (${reason}). Look at the diff for ${consultTarget} in your working directory (e.g. \`git diff\`). Decide: is there enough substantive, human-authored executable-code change here to warrant a simplify pass (reuse/quality/efficiency)? Bias toward NOT running — a wrong "yes" auto-mutates low-value code, a wrong "no" merely leaves it untidy. Return EXACTLY one JSON object: {"run": <boolean>, "reason": "<one line>"}.`;
}

function reportLegPrompt(consultTarget: string, skillDir: string, smoke: boolean): string {
  if (smoke) {
    return `[ce-simplify-external-consult] Wiring test. Return EXACTLY one JSON object and nothing else: {"status": "SMOKE OK", "findings": []}. Do nothing else.`;
  }
  return `[ce-simplify-external-consult]

Run the compound-engineering ce-simplify-code REVIEWERS on YOUR CURRENT working directory — it is a frozen snapshot checkout of the repository under review. This is a REPORT-ONLY consult: you run the reviewer phase and return findings; you apply nothing.

How to execute it:
- If your available skills include \`ce-simplify-code\`, invoke it — but only its Steps 1-2 (scope + the three persona reviewers), per the hard rules below.
- ${skillFallbackLine(skillDir)} Simplification scope: ${consultTarget}.

${consultHardRules({
  forbiddenSkills: ["se-simplify"],
  skillDir,
  personaListLocation: "The report's reviewer list",
  noChangesRules: SIMPLIFY_REPORT_NO_CHANGES_RULES,
  extraRules: SIMPLIFY_REPORT_EXTRA_RULES,
  finalOutput: {
    kind: "rawObject",
    objectDescription: "an object {status, findings[]} where findings is the aggregated reviewer output",
  },
})}`;
}

function applyPrompt(applySet: unknown[], contradictions: unknown[]): string {
  return `[ce-simplify-external-consult]

You are the SINGLE apply owner for a cross-model simplify pass. Two independent reviewers (claude + opencode) already reviewed a frozen snapshot; their agreed + attributed findings are below. Apply them to YOUR CURRENT working directory (the live repo), editing files in place. Do NOT commit, push, or switch branches — leave the edits uncommitted for the caller to commit.

APPLY SET (${applySet.length} finding(s) — consensus + unique; apply each unless a hard rule below forces a skip):
${JSON.stringify(applySet, null, 2)}

EXCLUDED — contradictory findings the two legs disagreed on. Do NOT apply these; they are shown only so you do not "helpfully" act on them:
${JSON.stringify(contradictions, null, 2)}

${consultHardRules({
  forbiddenSkills: ["se-simplify"],
  skillDir: "(not used — findings are provided inline above)",
  personaListLocation: "The apply report's applied list",
  noChangesRules: [
    "APPLY ONLY the findings in the APPLY SET above. Do NOT re-review, do NOT hunt for new issues, do NOT apply anything in the EXCLUDED list.",
  ],
  extraRules: SIMPLIFY_APPLY_SAFETY_RULES,
  finalOutput: {
    kind: "wrapped",
    jsonField: "report",
    jsonValueDescription: "a short prose summary of what you applied per dimension (reuse/quality/efficiency) and what you skipped and why",
  },
})}`;
}

export default smithers((ctx) => {
  const input = ctx.input;
  const smoke = input.smoke ?? false;
  const repoPath = (input.repoPath?.trim() || process.env.SIMPLIFY_REPO || "").trim();
  const validateCmd = (input.validateCmd ?? "").trim();
  const validateTimeoutMs = input.validateTimeoutMs ?? 10 * 60_000;
  const baseSha = input.baseSha ?? "";
  const target = input.target ?? "";
  const useClassifier = input.useClassifier ?? true;
  const preScanned = input.preScanned ?? false;

  const gateDeterm = ctx.outputMaybe("gate", { nodeId: "gate-determ" });
  const classifyOut = ctx.outputMaybe("classifier", { nodeId: "gate-classify" });
  const classifyCrash = ctx.outputMaybe("failed", { nodeId: "gate-classify-crashed" });
  const staged = ctx.outputMaybe("stage", { nodeId: "stage" });
  const claudeLeg = ctx.outputMaybe("review", { nodeId: "leg-claude" });
  const claudeCrash = ctx.outputMaybe("failed", { nodeId: "leg-claude-crashed" });
  const opencodeLeg = ctx.outputMaybe("review", { nodeId: "leg-opencode" });
  const opencodeCrash = ctx.outputMaybe("failed", { nodeId: "leg-opencode-crashed" });
  const synthOut = ctx.outputMaybe("synth", { nodeId: "synth" });
  const preApplyOut = ctx.outputMaybe("preApply", { nodeId: "pre-apply" });
  const applyOut = ctx.outputMaybe("applyReport", { nodeId: "apply" });
  const applyCrash = ctx.outputMaybe("failed", { nodeId: "apply-crashed" });
  const verifyOut = ctx.outputMaybe("verify", { nodeId: "verify" });

  // Resolve the gate decision (deterministic → optional classifier). Undefined
  // `decided` = still waiting (classifier pending).
  const gateResolution = ((): { decided: boolean; run: boolean; reason: string; source: string } => {
    if (!gateDeterm) return { decided: false, run: false, reason: "", source: "" };
    if (gateDeterm.run) return { decided: true, run: true, reason: gateDeterm.reason, source: gateDeterm.source };
    if (!gateDeterm.inconclusive) return { decided: true, run: false, reason: gateDeterm.reason, source: gateDeterm.source };
    if (!useClassifier || smoke) return { decided: true, run: false, reason: `${gateDeterm.reason}; no classifier — skip-when-unsure`, source: "deterministic" };
    if (classifyOut) return { decided: true, run: classifyOut.run, reason: `classifier: ${classifyOut.reason || (classifyOut.run ? "worth simplifying" : "not worth simplifying")}`, source: "classifier" };
    if (classifyCrash) return { decided: true, run: false, reason: "classifier failed — skip-when-unsure", source: "classifier" };
    return { decided: false, run: false, reason: "", source: "" };
  })();

  const parsedSynth: SimplifyMergeResult | undefined = synthOut ? (JSON.parse(synthOut.merged) as SimplifyMergeResult) : undefined;
  const applySet = parsedSynth?.applySet ?? [];
  const willApply = parsedSynth?.status === "ok" && applySet.length > 0 && validateCmd !== "";

  const legsSettled = (claudeLeg !== undefined || claudeCrash !== undefined) && (opencodeLeg !== undefined || opencodeCrash !== undefined);

  // Agents are built per render — their cwd only exists after the stage task.
  const claudeAgent = staged ? makeClaudeReviewAgent({ cwd: staged.snapshotDir, profile: "simplifyReview" }) : undefined;
  const opencodeAgent = staged ? makeOpencodeReviewAgent({ cwd: staged.snapshotDir }) : undefined;
  const applyAgent = repoPath ? makeSimplifyApplyAgent({ cwd: repoPath, timeoutMs: APPLY_TIMEOUT_MS, maxBudgetUsd: APPLY_BUDGET_USD }) : undefined;
  const classifierAgent = repoPath && !smoke ? makeSimplifyClassifierAgent({ cwd: repoPath }) : undefined;

  const runNodes: unknown[] = [];
  if (gateResolution.decided && gateResolution.run) {
    runNodes.push(
      <Task id="stage" output={outputs.stage} retries={0}>
        {() => stage(repoPath, target, baseSha, smoke, preScanned)}
      </Task>,
    );
    if (staged) {
      runNodes.push(
        <Parallel>
          <TryCatchFinally
            id="guard-leg-claude"
            try={
              <Task id="leg-claude" output={outputs.review} agent={claudeAgent} retries={AGENT_PROFILES.simplifyReview.retries}>
                {reportLegPrompt(staged.consultTarget, staged.skillDir, smoke)}
              </Task>
            }
            catch={
              <Task id="leg-claude-crashed" output={outputs.failed}>
                {() => ({ agent: "claude" })}
              </Task>
            }
          />
          <TryCatchFinally
            id="guard-leg-opencode"
            try={
              <Task id="leg-opencode" output={outputs.review} agent={opencodeAgent} retries={AGENT_PROFILES.opencodeReview.retries}>
                {reportLegPrompt(staged.consultTarget, staged.skillDir, smoke)}
              </Task>
            }
            catch={
              <Task id="leg-opencode-crashed" output={outputs.failed}>
                {() => ({ agent: "opencode" })}
              </Task>
            }
          />
        </Parallel>,
      );
    }
    if (staged && legsSettled) {
      runNodes.push(
        <Task id="synth" output={outputs.synth} retries={0}>
          {() => {
            const legs: ReviewLeg[] = [
              { source: "claude", raw: claudeLeg ? JSON.stringify(claudeLeg) : undefined },
              { source: "opencode", raw: opencodeLeg ? JSON.stringify(opencodeLeg) : undefined },
            ];
            return { merged: JSON.stringify(mergeSimplifyLegs(legs)) };
          }}
        </Task>,
      );
    }
    // Apply path renders only when there is a non-empty apply set AND a
    // validate-cmd to prove behavior with. Empty set / no validate / degraded
    // synth all terminate at output without touching repoPath.
    if (parsedSynth && willApply) {
      runNodes.push(
        <Task id="pre-apply" output={outputs.preApply} retries={0}>
          {() => {
            const head = git(repoPath, "rev-parse", "HEAD");
            const stashRef = stashCreateSafe(repoPath);
            const dirtyBefore = git(repoPath, "status", "--porcelain");
            return { head, stashRef, dirtyBefore };
          }}
        </Task>,
      );
      if (preApplyOut) {
        runNodes.push(
          <TryCatchFinally
            id="guard-apply"
            try={
              <Task id="apply" output={outputs.applyReport} agent={applyAgent} retries={0}>
                {applyPrompt(applySet, parsedSynth.contradictions)}
              </Task>
            }
            catch={
              <Task id="apply-crashed" output={outputs.failed}>
                {() => ({ agent: "apply" })}
              </Task>
            }
          />,
        );
      }
      if (preApplyOut && (applyOut || applyCrash)) {
        runNodes.push(
          <Task id="verify" output={outputs.verify} retries={0}>
            {() => {
              const pre = preApplyOut;
              const revert = (): void => {
                const restoreRef = pre.stashRef || pre.head;
                try {
                  git(repoPath, "checkout", restoreRef, "--", ".");
                } catch {}
                // clean untracked only when the tree was clean before apply (the
                // pipeline case) — never nuke a standalone operator's pre-existing
                // untracked files.
                if (pre.dirtyBefore === "") {
                  try {
                    git(repoPath, "clean", "-fd");
                  } catch {}
                }
              };
              if (applyCrash) {
                revert();
                return { status: "degraded" as const, appliedEdits: false, validateExitCode: null, reverted: true, reason: "apply leg crashed — reverted, no tidy this run" };
              }
              const dirtyNow = git(repoPath, "status", "--porcelain");
              if (dirtyNow === pre.dirtyBefore) {
                return { status: "ok" as const, appliedEdits: false, validateExitCode: null, reverted: false, reason: "apply leg made no edits (all findings skipped as false-positive)" };
              }
              const validate = runValidateCmd(validateCmd, repoPath, validateTimeoutMs);
              if (validate.exitCode === 0) {
                return { status: "ok" as const, appliedEdits: true, validateExitCode: 0, reverted: false, reason: "applied, validate-cmd passed — behavior preserved" };
              }
              revert();
              return {
                status: "degraded" as const,
                appliedEdits: false,
                validateExitCode: validate.exitCode,
                reverted: true,
                reason: `validate-cmd failed (exit ${validate.exitCode}) — whole apply reverted. Tail: ${validate.output.slice(-400)}`,
              };
            }}
          </Task>,
        );
      }
    }
  }

  // Terminal predicate: when the run has reached an end state, render output.
  const terminal = ((): boolean => {
    if (!gateResolution.decided) return false;
    if (!gateResolution.run) return true; // skipped
    if (parsedSynth && parsedSynth.status === "degraded") return true; // zero legs
    if (parsedSynth && !willApply) return true; // empty apply set OR no validate-cmd
    if (verifyOut) return true;
    return false;
  })();

  const children: unknown[] = [
    <Task id="gate-determ" output={outputs.gate} retries={0}>
      {() => {
        if (smoke) return { run: true, reason: "smoke", inconclusive: false, source: "smoke" };
        if (repoPath === "") throw new Error("se-simplify: no repoPath input and no SIMPLIFY_REPO env — cannot resolve a repo to simplify.");
        const base = resolveBase(repoPath, baseSha);
        const numstat = git(repoPath, "diff", "--numstat", `${base}..HEAD`);
        const decision = shouldRunSimplify(parseNumstat(numstat));
        return { run: decision.run, reason: decision.reason, inconclusive: decision.inconclusive, source: "deterministic" };
      }}
    </Task>,
  ];

  if (gateDeterm && gateDeterm.inconclusive && useClassifier && !smoke && !classifyOut && !classifyCrash) {
    children.push(
      <TryCatchFinally
        id="guard-gate-classify"
        try={
          <Task id="gate-classify" output={outputs.classifier} agent={classifierAgent} retries={0}>
            {classifierPrompt(target.trim() || `base:${baseSha || "auto"}`, gateDeterm.reason)}
          </Task>
        }
        catch={
          <Task id="gate-classify-crashed" output={outputs.failed}>
            {() => ({ agent: "classifier" })}
          </Task>
        }
      />,
    );
  }

  if (runNodes.length > 0) {
    children.push(
      <TryCatchFinally
        id="simplify-run"
        try={<Sequence>{runNodes as never[]}</Sequence>}
        finally={
          <Task id="cleanup" output={outputs.failed}>
            {() => {
              if (staged) cleanupSnapshot(repoPath, staged.snapshotDir);
              return { agent: "cleanup" };
            }}
          </Task>
        }
      />,
    );
  }

  if (terminal) {
    children.push(
      <Task id="output" output={outputs.output} retries={0}>
        {() => {
          const claudeStatus: "ok" | "failed" | "n/a" = claudeLeg ? "ok" : claudeCrash ? "failed" : "n/a";
          const opencodeStatus: "ok" | "failed" | "n/a" = opencodeLeg ? "ok" : opencodeCrash ? "failed" : "n/a";
          const base: z.infer<typeof outputSchema> = {
            status: "skipped",
            reason: gateResolution.reason,
            stageDir: staged?.stageDir,
            consultTarget: staged?.consultTarget,
            claudeStatus,
            opencodeStatus,
            appliedEdits: false,
            appliedCount: 0,
            contradictionCount: parsedSynth?.contradictions.length ?? 0,
            validateExitCode: null,
            reverted: false,
          };

          if (!gateResolution.run) {
            return { ...base, status: "skipped", reason: `simplify skipped: ${gateResolution.reason}` };
          }

          // Persist the synthesis + verify report for the caller / human.
          let reportPath: string | undefined;
          if (staged && parsedSynth) {
            const outDir = path.join(staged.stageDir, "out");
            fs.mkdirSync(outDir, { recursive: true });
            reportPath = path.join(outDir, "simplify.report.json");
            fs.writeFileSync(reportPath, JSON.stringify({ synth: parsedSynth, verify: verifyOut ?? null, apply: applyOut ?? null }, null, 2));
          }

          if (parsedSynth && parsedSynth.status === "degraded") {
            return { ...base, status: "degraded", reason: `simplify degraded: ${parsedSynth.reasons.join("; ")}`, reportPath };
          }
          if (parsedSynth && applySet.length === 0) {
            return { ...base, status: "ok", reason: `nothing to apply — ${parsedSynth.reasons.join("; ") || "no consensus/unique findings"}`, reportPath };
          }
          if (parsedSynth && applySet.length > 0 && validateCmd === "") {
            return { ...base, status: "degraded", reason: "refused to apply: no validate-cmd to verify behavior preservation (standalone requires --validate-cmd)", reportPath };
          }
          if (verifyOut) {
            return {
              ...base,
              status: verifyOut.status,
              reason: verifyOut.reason,
              appliedEdits: verifyOut.appliedEdits,
              appliedCount: verifyOut.appliedEdits ? applySet.length : 0,
              validateExitCode: verifyOut.validateExitCode,
              reverted: verifyOut.reverted,
              reportPath,
            };
          }
          return { ...base, status: "degraded", reason: "simplify reached output in an unexpected state", reportPath };
        }}
      </Task>,
    );
  }

  return (
    <Workflow name="se-simplify">
      <Sequence>{children as never[]}</Sequence>
    </Workflow>
  );
});
