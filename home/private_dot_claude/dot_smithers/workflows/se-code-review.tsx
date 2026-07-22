/** @jsxImportSource smithers-orchestrator */
// External code-review harness: stage (frozen worktree snapshot) →
// Parallel(claude, opencode full plugin review in mode:agent) → collect.
// Deterministic orchestration lives here; the calling skill only reads the
// run output. Run from THIS directory so smithers state (smithers.db,
// .smithers/) stays out of the target repo:
//   cd ~/.claude/.smithers && CODE_REVIEW_REPO=/abs/repo ./node_modules/.bin/smithers up workflows/se-code-review.tsx \
//     --input '{"target":""}'
// Staging lives in /tmp/ce-code-review — opencode reads it via the
// permission.external_directory allow in ~/.config/opencode/opencode.json.
import { createSmithers, ClaudeCodeAgent, OpenCodeAgent, TryCatchFinally } from "smithers-orchestrator";
import { z } from "zod/v4";
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

const inputSchema = z.object({
  target: z
    .string()
    .default("")
    .describe("Review target tokens forwarded verbatim (PR url/number, branch, base:<ref>, plan:<path>, depth:/grouping:). Empty = current branch vs auto-detected base."),
  smoke: z.boolean().default(false).describe("Wiring test: trivial prompts, no real review."),
});

const stageSchema = z.object({
  stageDir: z.string(),
  skillDir: z.string(),
  pluginVersion: z.string(),
  snapshotDir: z.string(),
  snapshotSha: z.string(),
  consultTarget: z.string(),
});

const reviewSchema = z.object({
  report: z
    .string()
    .refine((s) => {
      if (s.startsWith("SMOKE OK")) return true;
      try {
        const parsed = JSON.parse(s);
        return typeof parsed?.status === "string";
      } catch {
        return false;
      }
    }, "Not a mode:agent review report: must be the plugin's raw JSON object (with a 'status' field) serialized into this string — contract set by the consult prompt, not the plugin.")
    .describe("The plugin's full mode:agent JSON review (status/verdict/findings/...) as a string."),
});

const failedSchema = z.object({ agent: z.string() });

const outputSchema = z.object({
  stageDir: z.string(),
  pluginVersion: z.string(),
  snapshotSha: z.string(),
  consultTarget: z.string(),
  claudeStatus: z.enum(["ok", "failed"]),
  opencodeStatus: z.enum(["ok", "failed"]),
  claudeReportPath: z.string().optional(),
  opencodeReportPath: z.string().optional(),
});

const { Workflow, Task, Sequence, Parallel, smithers, outputs } = createSmithers({
  input: inputSchema,
  stage: stageSchema,
  review: reviewSchema,
  failed: failedSchema,
  output: outputSchema,
});

const repoDir = process.env.CODE_REVIEW_REPO ?? process.cwd();

// Native structured-output enforcement (claude CLI --json-schema). Smithers
// does NOT derive this from the Task's Zod schema — without it the final
// message is free-form text and capture fails on subagent-heavy sessions.
const reportJsonSchema = JSON.stringify({
  type: "object",
  properties: { report: { type: "string" } },
  required: ["report"],
});

// Per-leg caps sized from _smithers_attempts history, not a shared guess:
// the claude leg (up to ~9 reviewer personas on a big diff) blew a 15-min cap
// on platform-3 (run 46dec4cf — and smithers reaped the timed-out attempt
// only at ~28 min wall-clock, so the real worst case exceeds the nominal
// maxAttempts × cap). Opencode finishes in 3-6 min. The calling skill's wait
// cap must exceed maxAttempts × the larger cap plus reap lag (~55 min).
const CLAUDE_REVIEW_TIMEOUT_MS = 25 * 60_000;
const OPENCODE_REVIEW_TIMEOUT_MS = 15 * 60_000;

function git(cwd: string, ...args: string[]): string {
  return execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8" }).trim();
}

function resolvePluginSkillDir(): { dir: string; version: string } {
  const base = path.join(os.homedir(), ".claude/plugins/cache/compound-engineering-plugin/compound-engineering");
  const versions = fs.readdirSync(base).sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
  const latest = versions[versions.length - 1];
  return { dir: path.join(base, latest, "skills/ce-code-review"), version: latest };
}

function detectBaseRef(): string {
  try {
    const head = git(repoDir, "symbolic-ref", "refs/remotes/origin/HEAD");
    return head.replace("refs/remotes/", "");
  } catch {
    for (const ref of ["origin/main", "main", "master"]) {
      try {
        git(repoDir, "rev-parse", "--verify", ref);
        return ref;
      } catch {}
    }
    throw new Error("Cannot detect a base branch (origin/HEAD, origin/main, main, master all missing).");
  }
}

// Freeze the review target so the concurrent LOCAL interactive review (which
// may apply fixes and commit mid-run) can't move the diff under the external
// agents. `git stash create` captures dirty tracked state as a commit without
// touching the working tree (untracked files are NOT included — matching the
// plugin's own default scope); the detached worktree checks that commit out
// under /tmp/ce-code-review where opencode is allowed to read.
function stage(target: string) {
  const stageDir = path.join("/tmp/ce-code-review", `run-${Date.now()}`);
  const skillDir = path.join(stageDir, "skill");
  fs.mkdirSync(skillDir, { recursive: true });
  const plugin = resolvePluginSkillDir();
  fs.cpSync(plugin.dir, skillDir, { recursive: true });

  const snapshotSha = git(repoDir, "stash", "create") || git(repoDir, "rev-parse", "HEAD");
  const snapshotDir = path.join(stageDir, "repo");
  git(repoDir, "worktree", "add", "--detach", snapshotDir, snapshotSha);

  const consultTarget = target.trim() || `base:${git(repoDir, "merge-base", snapshotSha, detectBaseRef())}`;
  return { stageDir, skillDir, pluginVersion: plugin.version, snapshotDir, snapshotSha, consultTarget };
}

function cleanupSnapshot(snapshotDir: string) {
  try {
    git(repoDir, "worktree", "remove", "--force", snapshotDir);
  } catch {
    try {
      git(repoDir, "worktree", "prune");
    } catch {}
  }
}

function reviewPrompt(consultTarget: string, skillDir: string, smoke: boolean): string {
  if (smoke) {
    return `[ce-code-review-external-consult] Wiring test. Run \`git log -1 --format=%H\` in your working directory, then return report set to "SMOKE OK: <that sha>". Do nothing else.`;
  }
  return `[ce-code-review-external-consult]

Execute the compound-engineering code-review workflow in mode:agent on YOUR CURRENT working directory — it is a frozen snapshot checkout of the repository under review.

How to execute it:
- If your available skills include \`compound-engineering:ce-code-review\`, invoke it with args "mode:agent ${consultTarget}".
- Otherwise, read ${skillDir}/SKILL.md and follow it directly, treating ${skillDir} as the skill's base directory (it references its own files under it). Where it dispatches subagents, use YOUR subagent tool. Review target: ${consultTarget}.

Hard rules:
- NEVER invoke a skill named bare \`se-code-review\` — that is a wrapper that spawns external consults and would recurse.
- NO CHANGES, JUST REPORT: mode:agent is report-only. Do not create, edit, or delete ANY file, never commit, never push, never switch branches. The snapshot and the repo are read-only context.
- Your FINAL message must be EXACTLY one JSON object and nothing else — no prose before or after it: {"report": "<the plugin's full mode:agent JSON review serialized as a string>"}. A final message that is not that single JSON object is a failed run.`;
}

export default smithers((ctx) => {
  const staged = ctx.outputMaybe("stage", { nodeId: "stage" });
  const claudeReview = ctx.outputMaybe("review", { nodeId: "review-claude" });
  const opencodeReview = ctx.outputMaybe("review", { nodeId: "review-opencode" });

  // Agents are built per render because their cwd — the frozen snapshot — only
  // exists after the stage task runs.
  const claudeAgent = staged
    ? new ClaudeCodeAgent({
        cwd: staged.snapshotDir,
        permissionMode: "acceptEdits",
        // Consensus leg, not the deep one — the local personas already run on
        // the session's top model. Sonnet matches se-pipeline verify-code and
        // se-doc-review (which caught the Batch-5 P0s at this tier); unpinned,
        // cost and quality float with the CLI's account default. fallbackModel
        // rides out a Max-subscription rate-limit on the primary.
        model: "claude-sonnet-5",
        fallbackModel: "claude-haiku-4-5",
        timeoutMs: CLAUDE_REVIEW_TIMEOUT_MS,
        // Circuit breaker against a runaway agent, NOT a cost target: the cap
        // re-arms on retry, so worst case ≈ 2 × this. Actual spend: grep
        // total_cost_usd in the run log.
        maxBudgetUsd: 15,
        jsonSchema: reportJsonSchema,
        // Default stream-json capture is safe here: the chunk-join corruption
        // on subagent-heavy runs was fixed by 95b4f5736, which IS inside
        // v0.27.0 (verified by spike run a9b4b686 — se-pipeline plan, KTD9).
      })
    : undefined;
  const opencodeAgent = staged
    ? new OpenCodeAgent({
        cwd: staged.snapshotDir,
        model: "openai/gpt-5.5",
        timeoutMs: OPENCODE_REVIEW_TIMEOUT_MS,
      })
    : undefined;

  return (
    <Workflow name="code-review-externals">
      <Sequence>
        <Task id="stage" output={outputs.stage}>
          {() => stage(ctx.input.target ?? "")}
        </Task>
        {staged ? (
          <Parallel>
            <TryCatchFinally
              id="guard-claude"
              try={
                <Task id="review-claude" output={outputs.review} agent={claudeAgent} retries={1}>
                  {reviewPrompt(staged.consultTarget, staged.skillDir, ctx.input.smoke ?? false)}
                </Task>
              }
              catch={
                <Task id="review-claude-failed" output={outputs.failed}>
                  {() => ({ agent: "claude" })}
                </Task>
              }
            />
            <TryCatchFinally
              id="guard-opencode"
              try={
                <Task id="review-opencode" output={outputs.review} agent={opencodeAgent} retries={1}>
                  {reviewPrompt(staged.consultTarget, staged.skillDir, ctx.input.smoke ?? false)}
                </Task>
              }
              catch={
                <Task id="review-opencode-failed" output={outputs.failed}>
                  {() => ({ agent: "opencode" })}
                </Task>
              }
            />
          </Parallel>
        ) : null}
        {staged ? (
          <Task id="output" output={outputs.output}>
            {() => {
              const outDir = path.join(staged.stageDir, "out");
              fs.mkdirSync(outDir, { recursive: true });
              const result: z.infer<typeof outputSchema> = {
                stageDir: staged.stageDir,
                pluginVersion: staged.pluginVersion,
                snapshotSha: staged.snapshotSha,
                consultTarget: staged.consultTarget,
                claudeStatus: claudeReview ? "ok" : "failed",
                opencodeStatus: opencodeReview ? "ok" : "failed",
              };
              if (claudeReview) {
                result.claudeReportPath = path.join(outDir, "claude.review.json");
                fs.writeFileSync(result.claudeReportPath, claudeReview.report);
              }
              if (opencodeReview) {
                result.opencodeReportPath = path.join(outDir, "opencode.review.json");
                fs.writeFileSync(result.opencodeReportPath, opencodeReview.report);
              }
              cleanupSnapshot(staged.snapshotDir);
              return result;
            }}
          </Task>
        ) : null}
      </Sequence>
    </Workflow>
  );
});
