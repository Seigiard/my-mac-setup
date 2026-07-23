// Shared prose for external-consult prompts (se-code-review, se-doc-review,
// se-pipeline verify-code). The Hard rules block drifted three ways before
// this module existed — recursion guard, persona-mechanics contract, and the
// final-JSON contract are one policy and must read identically everywhere.
// Workflow-specific lines (no-changes wording, envelope content rules) come
// in as parameters so the ORDER stays fixed: recursion → persona →
// no-changes → extras → final JSON.

export interface ConsultHardRulesOptions {
  forbiddenSkills: string[];
  skillDir: string;
  personaListLocation: string;
  noChangesRules: string[];
  extraRules?: string[];
  jsonField: "report" | "envelope";
  jsonValueDescription: string;
}

export function consultHardRules(options: ConsultHardRulesOptions): string {
  const forbidden = options.forbiddenSkills.map((s) => `\`${s}\``).join(" or ");
  const rules = [
    `NEVER invoke ${options.forbiddenSkills.length > 1 ? "skills" : "a skill"} named bare ${forbidden} — they spawn external orchestrations and would recurse.`,
    `EXECUTE THE PERSONA MECHANICS FOR REAL: run the skill's reviewer-persona selection, then dispatch ONE subagent PER selected persona whose prompt is the FULL text of that persona's file under ${options.skillDir} — not a summary you write yourself. ${options.personaListLocation} must name exactly the personas actually executed as subagents; collapsing them into fewer generic reviewers is a failed run.`,
    ...options.noChangesRules,
    ...(options.extraRules ?? []),
    `Your FINAL message must be EXACTLY one JSON object and nothing else — no prose before or after it: {"${options.jsonField}": "${options.jsonValueDescription}"}. Emit it exactly once, as the very last message; never emit placeholder JSON like {"${options.jsonField}": "PENDING"} earlier in the session. A final message that is not that single JSON object is a failed run.`,
  ];
  return `Hard rules:\n${rules.map((r) => `- ${r}`).join("\n")}`;
}

// The skill-fallback line is verbatim-identical across all three consults;
// workflow-specific tails (review target, doc path) are appended by the
// caller.
export function skillFallbackLine(skillDir: string): string {
  return `Otherwise, read ${skillDir}/SKILL.md and follow it directly, treating ${skillDir} as the skill's base directory (it references its own files under it). Where it dispatches subagents, use YOUR subagent tool.`;
}
