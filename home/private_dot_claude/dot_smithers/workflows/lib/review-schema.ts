// Single source of the natural-shape code-review leg contract. The plugin's
// mode:agent review is a JSON object with a top-level string `status` field
// (plus verdict/findings/…); the leg captures that object directly instead of
// the old {report: "<stringified JSON>"} double-wrap, so native structured
// output and the engine's JSON salvage cascade both land on the same shape.
// Extra fields pass through untouched — lib/review-merge.ts stays the tolerant
// consumer that reads `findings`, no deep validation here. Imported by
// se-code-review.tsx and the se-pipeline verify-code legs; never hand-mirrored.
import { z } from "zod/v4";

// `findings` is DECLARED, not left to looseObject passthrough: smithers
// persists a Task's output by projecting SCHEMA-DECLARED fields to columns and
// DROPS undeclared keys (verified — an undeclared `findings` array does not
// survive `ctx.outputMaybe`). The review/simplify merges both read a top-level
// `findings` array off the captured leg, so it must be a declared field or it
// vanishes and every leg parses as failed. Optional + passthrough keeps the
// plugin's other fields (verdict/severity/…) shape-tolerant while guaranteeing
// findings round-trips.
export const reviewLegSchema = z.looseObject({
  status: z.string(),
  findings: z.array(z.unknown()).optional(),
});

export type NaturalReviewReport = z.infer<typeof reviewLegSchema>;

// The claude CLI --json-schema payload for profile:'codeReview'. Mirrors
// reviewLegSchema — required string `status`, additional properties allowed so
// the plugin's verdict/findings survive capture. Serialized because the agent
// constructor takes the schema as a string (see stringFieldJsonSchema).
export function reviewLegJsonSchema(): string {
  return JSON.stringify({
    type: "object",
    properties: { status: { type: "string" }, findings: { type: "array" } },
    required: ["status"],
  });
}
