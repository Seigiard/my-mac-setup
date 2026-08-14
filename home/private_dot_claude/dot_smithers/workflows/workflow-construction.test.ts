import { describe, expect, test } from "bun:test";
import { createSmithers } from "smithers-orchestrator";
import { z } from "zod/v4";

// Every workflow file calls createSmithers at module load, and createSmithers
// validates the output schemas right there — before any node exists. Importing
// the module is therefore the whole check.
//
// It is worth having because `bun build` cannot do it: it resolves the same
// module graph without type-checking and without instantiating anything, so a
// green build says nothing about whether a run can start. se-flow.tsx declared
// an output field named `runId`, which smithers reserves as an internal column,
// and every launch was refused for a day while the build stayed green.
//
// What this does NOT prove: that a run advances. A Task handed `bind={undefined}`
// parks at its first node, and no import-time check can see that — it needs a
// live compute-only smoke run. A green suite here means "constructible", never
// "works".
const WORKFLOWS = [
  "./se-flow.tsx",
  "./se-pipeline.tsx",
  "./se-code-review.tsx",
  "./se-doc-review.tsx",
  "./se-simplify.tsx",
];

describe("workflow construction", () => {
  for (const specifier of WORKFLOWS) {
    test(`${specifier} constructs at import`, async () => {
      // #given a workflow file whose createSmithers call runs at module load
      // #when it is imported
      const module = await import(specifier);

      // #then construction completed and the driver has a workflow to run
      expect(module.default).toBeDefined();
    });
  }

  test("createSmithers still rejects a reserved output field", () => {
    // #given a schema shadowing one of smithers' internal columns
    const build = () => createSmithers({ input: z.object({ a: z.string() }), bad: z.object({ runId: z.string() }) });

    // #when / #then it throws at construction, which is what the imports above
    // rely on. Were the engine to stop validating eagerly, those imports would
    // quietly stop checking anything, and this canary is what says so.
    expect(build).toThrow(/reserved field name/);
  });
});
