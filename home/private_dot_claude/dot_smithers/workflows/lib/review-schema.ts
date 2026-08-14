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
// containment, not exact match.
const TERMINAL_REVIEW_STATUS = /\b(complete|completed|done|ok|success|succeeded)\b/i;

function isTerminalReviewStatus(status: string): boolean {
  return TERMINAL_REVIEW_STATUS.test(status);
}

// States that mean the leg did not finish its review: a crash, a timeout, or a
// progress state salvaged from a session that ended before synthesis. Findings
// carried alongside one of these are partial at best.
const FAILED_REVIEW_STATUS =
  /\b(fail|failed|failing|failure|error|errored|crash|crashed|abort|aborted|cancelled|canceled|timeout|timed[ _-]?out|pending|queued|running|in[ _-]?progress|waiting|incomplete|partial|unknown)\b/i;

// "not completed", "no longer running" — a negated success word is a failure,
// and plain containment would read the success word and pass it.
const NEGATED_TERMINAL = /\b(not|no longer|never)\s+(complete|completed|done|ok|success|succeeded)\b/i;

// "no errors", "0 failures", "free of errors" — a failure word under a negation
// describes health, and plain containment would read it as the failure itself.
const NEGATED_FAILURE = /\b(no|zero|0|without|free of)\s+\w+/gi;

// Whether a leg's payload may be trusted, judged by the report rather than by
// the adjective the model chose. This inverts the older allowlist rule, and the
// inversion is the point (docs/issues/2026-08-14-002): a leg that returned a
// parsed findings array is a leg that ran, so an unforeseen synonym like
// "findings" must not discard it. Discarding cost more than a needless pause —
// the dropped leg's findings never reached the merged report, so a real P0
// could vanish while the run degraded for an apparently unrelated reason.
//
// Fail-closed survives where the evidence is genuinely absent: a status that is
// missing, non-string or empty reads as a malformed envelope, not as health.
// The caller checks the payload itself (a missing findings array already fails
// the leg before this is asked).
export function isUsableReviewLegStatus(status: unknown): boolean {
  if (typeof status !== "string" || status.trim() === "") return false;
  // Underscores are word characters, so `\bwaiting\b` does not see the word in
  // "waiting_for_reviewers" — the very status this vocabulary exists to catch.
  // Separators become spaces before any word-boundary test.
  const normalized = status.replace(/[_-]+/g, " ");
  if (NEGATED_TERMINAL.test(normalized)) return false;
  if (isTerminalReviewStatus(normalized)) return true;
  return !FAILED_REVIEW_STATUS.test(normalized.replace(NEGATED_FAILURE, " "));
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
