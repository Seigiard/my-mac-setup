import { describe, expect, test } from "bun:test";
import { consultHardRules, skillFallbackLine } from "./consult-prompt.ts";

const base = {
  forbiddenSkills: ["se-code-review"],
  skillDir: "/tmp/stage/skill",
  personaListLocation: "The report's reviewer list",
  noChangesRules: ["NO CHANGES, JUST REPORT: report-only."],
  finalOutput: { kind: "wrapped", jsonField: "report", jsonValueDescription: "<the review serialized as a string>" } as const,
};

describe("consultHardRules", () => {
  test("names every forbidden skill in the recursion guard", () => {
    const rules = consultHardRules({ ...base, forbiddenSkills: ["se-code-review", "se-pipeline"] });
    expect(rules).toContain("`se-code-review` or `se-pipeline`");
    expect(rules).toContain("skills named bare");
  });

  test("persona contract binds to the skill dir and the report's persona list", () => {
    const rules = consultHardRules(base);
    expect(rules).toContain("ONE subagent PER selected persona");
    expect(rules).toContain(base.skillDir);
    expect(rules).toContain(base.personaListLocation);
    expect(rules).toContain("failed run");
  });

  test("wrapped final-JSON contract uses the workflow's field and forbids early placeholders", () => {
    const rules = consultHardRules({
      ...base,
      finalOutput: { kind: "wrapped", jsonField: "envelope", jsonValueDescription: "<envelope text>" },
    });
    expect(rules).toContain('{"envelope": "<envelope text>"}');
    expect(rules).toContain('{"envelope": "PENDING"}');
  });

  test("rawObject final contract asks for the bare review object, no wrapper", () => {
    const rules = consultHardRules({
      ...base,
      finalOutput: { kind: "rawObject", objectDescription: "the plugin's full mode:agent review" },
    });
    expect(rules).toContain("the plugin's full mode:agent review");
    expect(rules).toContain("top-level string `status`");
    expect(rules).toContain('NOT wrapped in any {"report": ...}');
    expect(rules).not.toContain('{"report": "');
  });

  test("keeps rule order: recursion, persona, no-changes, extras, final JSON", () => {
    const rules = consultHardRules({ ...base, extraRules: ["EXTRA RULE"] });
    const lines = rules.split("\n");
    expect(lines[0]).toBe("Hard rules:");
    expect(lines[1]).toContain("NEVER invoke");
    expect(lines[2]).toContain("PERSONA MECHANICS");
    expect(lines[3]).toContain("NO CHANGES");
    expect(lines[4]).toBe("- EXTRA RULE");
    expect(lines[5]).toContain("FINAL message");
    expect(lines).toHaveLength(6);
  });
});

describe("skillFallbackLine", () => {
  test("references the skill dir and the caller's own subagent tool", () => {
    const line = skillFallbackLine("/tmp/stage/skill");
    expect(line).toContain("/tmp/stage/skill/SKILL.md");
    expect(line).toContain("YOUR subagent tool");
  });
});
