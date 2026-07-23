/** @jsxImportSource smithers-orchestrator */
// External doc-review harness: stage → Parallel(claude, opencode full plugin
// review) → collect. Deterministic orchestration lives here; the calling skill
// only reads the run output. Run from THIS directory so smithers state
// (smithers.db, .smithers/) stays out of the target repo:
//   cd ~/.claude/.smithers && DOC_REVIEW_REPO=/abs/repo ./node_modules/.bin/smithers up workflows/se-doc-review.tsx \
//     --input '{"docPath":"/abs/path/plan.md"}'
// Staging lives in /tmp/ce-doc-review — opencode reads it via the
// permission.external_directory allow in ~/.config/opencode/opencode.json.
import { createSmithers, TryCatchFinally } from "smithers-orchestrator";
import { z } from "zod/v4";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { AGENT_PROFILES, makeClaudeReviewAgent, makeOpencodeReviewAgent } from "./lib/agents.ts";

const inputSchema = z.object({
  docPath: z.string().describe("Absolute path to the document under review."),
  smoke: z.boolean().default(false).describe("Wiring test: trivial prompts, no real review."),
});

const stageSchema = z.object({
  stageDir: z.string(),
  skillDir: z.string(),
  pluginVersion: z.string(),
  docCopy: z.string(),
});

const reviewSchema = z.object({
  envelope: z
    .string()
    .refine(
      (s) => s.startsWith("SMOKE OK") || (s.length >= 500 && s.trimEnd().endsWith("Review complete")),
      "Not a review envelope: must be substantial and end with 'Review complete' (contract set by the consult prompt, not the plugin).",
    )
    .describe(
      "The full headless review envelope text (Applied fixes / Proposed fixes / Decisions / FYI / Residual concerns / Coverage), ending with 'Review complete'.",
    ),
});

const failedSchema = z.object({ agent: z.string() });

const outputSchema = z.object({
  stageDir: z.string(),
  pluginVersion: z.string(),
  claudeStatus: z.enum(["ok", "failed"]),
  opencodeStatus: z.enum(["ok", "failed"]),
  claudeEnvelopePath: z.string().optional(),
  opencodeEnvelopePath: z.string().optional(),
});

const { Workflow, Task, Sequence, Parallel, smithers, outputs } = createSmithers({
  input: inputSchema,
  stage: stageSchema,
  review: reviewSchema,
  failed: failedSchema,
  output: outputSchema,
});

const repoDir = process.env.DOC_REVIEW_REPO ?? process.cwd();

// Caps, models, and retry policy live in lib/agents.ts (docReview profile —
// deliberately cheaper than codeReview), including the incident history that
// sized them. The calling skill's wait cap must exceed (retries+1) × the
// claude timeout.
const claudeAgent = makeClaudeReviewAgent({ cwd: repoDir, profile: "docReview", jsonField: "envelope" });
const opencodeAgent = makeOpencodeReviewAgent({ cwd: repoDir });

function resolvePluginSkillDir(): { dir: string; version: string } {
  const base = path.join(os.homedir(), ".claude/plugins/cache/compound-engineering-plugin/compound-engineering");
  const versions = fs.readdirSync(base).sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
  const latest = versions[versions.length - 1];
  return { dir: path.join(base, latest, "skills/ce-doc-review"), version: latest };
}

// Staging in /tmp/ce-doc-review: outside the repo, readable by opencode only
// because ~/.config/opencode/opencode.json allows this path via
// permission.external_directory. If opencode starts rejecting reads here,
// check that config first.
function stage(docPath: string) {
  const stageDir = path.join("/tmp/ce-doc-review", `run-${Date.now()}`);
  const skillDir = path.join(stageDir, "skill");
  fs.mkdirSync(skillDir, { recursive: true });
  const plugin = resolvePluginSkillDir();
  fs.cpSync(plugin.dir, skillDir, { recursive: true });
  const docCopy = path.join(stageDir, "doc-under-review.md");
  fs.copyFileSync(docPath, docCopy);
  return { stageDir, skillDir, pluginVersion: plugin.version, docCopy };
}

function reviewPrompt(docCopy: string, skillDir: string, smoke: boolean): string {
  if (smoke) {
    return `[ce-doc-review-external-consult] Wiring test. Read the first line of ${docCopy}, then return envelope set to "SMOKE OK: <that first line>". Do nothing else.`;
  }
  return `[ce-doc-review-external-consult]

Execute the compound-engineering document-review workflow in HEADLESS mode on this document: ${docCopy}

How to execute it:
- If your available skills include \`compound-engineering:ce-doc-review\`, invoke it with args "mode:headless ${docCopy}".
- Otherwise, read ${skillDir}/SKILL.md and follow it directly, treating ${skillDir} as the skill's base directory (it references its own files under it). Where it dispatches subagents, use YOUR subagent tool.

Hard rules:
- NEVER invoke a skill named bare \`se-doc-review\` — that is a wrapper that spawns external consults and would recurse.
- EXECUTE THE PERSONA MECHANICS FOR REAL: run the skill's persona selection, then dispatch ONE subagent PER selected persona whose prompt is the FULL text of that persona's file under ${skillDir} — not a summary you write yourself. The envelope's Coverage section must name exactly the personas actually executed as subagents; collapsing them into fewer generic reviewers is a failed run.
- NO CHANGES, JUST REPORT: do not create, edit, or delete ANY file — including ${docCopy}. Where the workflow would apply a safe_auto fix, report it in the envelope as an applied-candidate finding with the exact suggested edit instead of making it.
- The repo at ${repoDir} is read-only context for feasibility verification.
- Your FINAL message must be EXACTLY one JSON object and nothing else — no prose before or after it: {"envelope": "<the full headless envelope text>"}. Emit it exactly once, as the very last message; never emit placeholder JSON like {"envelope": "PENDING"} earlier in the session.
- The envelope value is the review REPORT ITSELF, verbatim and complete: every section the workflow produced (applied-candidate fixes with exact suggested edits, proposed fixes, decisions, FYI, residual concerns, coverage), at least 500 characters, and its LAST line exactly: Review complete
- A status note ("Document review complete", a list of reviewers used, a summary of what you did) is NOT an envelope. It fails schema validation and the ENTIRE multi-persona review is discarded and re-run from scratch — all prior work wasted.`;
}

export default smithers((ctx) => {
  const staged = ctx.outputMaybe("stage", { nodeId: "stage" });
  const claudeReview = ctx.outputMaybe("review", { nodeId: "review-claude" });
  const opencodeReview = ctx.outputMaybe("review", { nodeId: "review-opencode" });
  return (
    <Workflow name="doc-review-externals">
      <Sequence>
        <Task id="stage" output={outputs.stage}>
          {() => stage(ctx.input.docPath)}
        </Task>
        {staged ? (
          <Parallel>
            <TryCatchFinally
              id="guard-claude"
              try={
                <Task id="review-claude" output={outputs.review} agent={claudeAgent} retries={AGENT_PROFILES.docReview.retries}>
                  {reviewPrompt(staged.docCopy, staged.skillDir, ctx.input.smoke ?? false)}
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
                <Task id="review-opencode" output={outputs.review} agent={opencodeAgent} retries={AGENT_PROFILES.opencodeReview.retries}>
                  {reviewPrompt(staged.docCopy, staged.skillDir, ctx.input.smoke ?? false)}
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
                claudeStatus: claudeReview ? "ok" : "failed",
                opencodeStatus: opencodeReview ? "ok" : "failed",
              };
              if (claudeReview) {
                result.claudeEnvelopePath = path.join(outDir, "claude.envelope.md");
                fs.writeFileSync(result.claudeEnvelopePath, claudeReview.envelope);
              }
              if (opencodeReview) {
                result.opencodeEnvelopePath = path.join(outDir, "opencode.envelope.md");
                fs.writeFileSync(result.opencodeEnvelopePath, opencodeReview.envelope);
              }
              return result;
            }}
          </Task>
        ) : null}
      </Sequence>
    </Workflow>
  );
});
