// Shared prose for external-consult prompts (se-code-review, se-doc-review,
// se-pipeline verify-code). The Hard rules block drifted three ways before
// this module existed — recursion guard, persona-mechanics contract, and the
// final-JSON contract are one policy and must read identically everywhere.
// Workflow-specific lines (no-changes wording, envelope content rules) come
// in as parameters so the ORDER stays fixed: recursion → persona →
// no-changes → extras → final JSON.

// The final-message contract differs by consult: doc-review wraps free-form
// markdown in {envelope: "..."} and work wraps its envelope in {report: "..."},
// but code-review now captures the plugin's natural review object directly
// (no wrapper) so native structured output and the engine's JSON salvage both
// land on the same shape. `wrapped` keeps the field-string form; `rawObject`
// asks for the bare object with a top-level string `status`.
export type FinalOutputContract =
  | { kind: "wrapped"; jsonField: "report" | "envelope"; jsonValueDescription: string }
  | { kind: "rawObject"; objectDescription: string };

export interface ConsultHardRulesOptions {
  forbiddenSkills: string[];
  skillDir: string;
  personaListLocation: string;
  noChangesRules: string[];
  extraRules?: string[];
  finalOutput: FinalOutputContract;
}

function finalOutputRule(final: FinalOutputContract): string {
  if (final.kind === "rawObject") {
    return `Your FINAL message must be EXACTLY one JSON object and nothing else — no prose before or after it: ${final.objectDescription}, emitted directly with a top-level string \`status\` field and NOT wrapped in any {"report": ...} or {"envelope": ...} envelope. Emit it exactly once, as the very last message; never emit a placeholder like {"status": "PENDING"} earlier in the session. A final message that is not that single JSON object is a failed run.`;
  }
  return `Your FINAL message must be EXACTLY one JSON object and nothing else — no prose before or after it: {"${final.jsonField}": "${final.jsonValueDescription}"}. Emit it exactly once, as the very last message; never emit placeholder JSON like {"${final.jsonField}": "PENDING"} earlier in the session. A final message that is not that single JSON object is a failed run.`;
}

export function consultHardRules(options: ConsultHardRulesOptions): string {
  const forbidden = options.forbiddenSkills.map((s) => `\`${s}\``).join(" or ");
  const rules = [
    `NEVER invoke ${options.forbiddenSkills.length > 1 ? "skills" : "a skill"} named bare ${forbidden} — they spawn external orchestrations and would recurse.`,
    `EXECUTE THE PERSONA MECHANICS FOR REAL: run the skill's reviewer-persona selection, then dispatch ONE subagent PER selected persona whose prompt is the FULL text of that persona's file under ${options.skillDir} — not a summary you write yourself. ${options.personaListLocation} must name exactly the personas actually executed as subagents; collapsing them into fewer generic reviewers is a failed run.`,
    ...options.noChangesRules,
    ...(options.extraRules ?? []),
    finalOutputRule(options.finalOutput),
  ];
  return `Hard rules:\n${rules.map((r) => `- ${r}`).join("\n")}`;
}

// The skill-fallback line is verbatim-identical across all three consults;
// workflow-specific tails (review target, doc path) are appended by the
// caller.
export function skillFallbackLine(skillDir: string): string {
  return `Otherwise, read ${skillDir}/SKILL.md and follow it directly, treating ${skillDir} as the skill's base directory (it references its own files under it). Where it dispatches subagents, use YOUR subagent tool.`;
}
