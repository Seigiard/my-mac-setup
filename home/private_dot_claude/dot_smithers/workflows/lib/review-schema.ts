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

// Terminal-success detection for a leg's free-form status. Real history holds
// "complete", "completed", "ok", "SMOKE OK", "reviewers complete", and
// "completed: <reviewer list>" as healthy values — so this is word-boundary
// containment, not exact match. Anything without a terminal word — "failed",
// "pending", "in_progress", "waiting_for_reviewers", any state the salvage
// cascade captured from a session that ended before synthesis — marks the LEG
// failed, so the gate's degraded/pause semantics apply instead of counting a
// dead leg as healthy-with-zero-findings. False-failing an exotic healthy
// status is the safe direction: it pauses for a human instead of passing.
const TERMINAL_REVIEW_STATUS = /\b(complete|completed|done|ok|success|succeeded)\b/i;

export function isTerminalReviewStatus(status: unknown): boolean {
  return typeof status === "string" && TERMINAL_REVIEW_STATUS.test(status);
}

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
