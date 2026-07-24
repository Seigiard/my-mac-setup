// Single source of the natural-shape code-review leg contract. The plugin's
// mode:agent review is a JSON object with a top-level string `status` field
// (plus verdict/findings/…); the leg captures that object directly instead of
// the old {report: "<stringified JSON>"} double-wrap, so native structured
// output and the engine's JSON salvage cascade both land on the same shape.
// Extra fields pass through untouched — lib/review-merge.ts stays the tolerant
// consumer that reads `findings`, no deep validation here. Imported by
// se-code-review.tsx and the se-pipeline verify-code legs; never hand-mirrored.
import { z } from "zod/v4";

export const reviewLegSchema = z.looseObject({
  status: z.string(),
});

export type NaturalReviewReport = z.infer<typeof reviewLegSchema>;

// The claude CLI --json-schema payload for profile:'codeReview'. Mirrors
// reviewLegSchema — required string `status`, additional properties allowed so
// the plugin's verdict/findings survive capture. Serialized because the agent
// constructor takes the schema as a string (see stringFieldJsonSchema).
export function reviewLegJsonSchema(): string {
  return JSON.stringify({
    type: "object",
    properties: { status: { type: "string" } },
    required: ["status"],
  });
}
