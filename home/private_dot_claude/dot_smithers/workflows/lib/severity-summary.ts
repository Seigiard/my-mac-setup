// Machine-readable severity summary for verify-doc review legs (KTD-A/KTD-B).
// The review envelope stays free-form markdown; a single SEVERITY line in a
// protected slot — the last non-empty line immediately before the terminal
// `Review complete` line — carries the counts the gate acts on. Parsing is
// tolerant: anything unexpected returns undefined and degrades to advisory,
// never a throw and never a scan of the envelope body (a decoy `SEVERITY:`
// line quoted in review prose must not spoof the gate).
import { z } from "zod/v4";

const SEVERITY_PREFIX = "SEVERITY: ";
const TERMINAL_LINE = "Review complete";

export const severitySchema = z.object({
  maxSeverity: z.string(),
  p0Count: z.number().int().nonnegative(),
  p1Count: z.number().int().nonnegative(),
});

export type SeveritySummary = z.infer<typeof severitySchema>;

function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0;
}

// Protected-slot extraction (KTD-B): only the last non-empty line immediately
// before the terminal `Review complete` line is considered. A misordered
// trailing pair (SEVERITY after Review complete) or a non-SEVERITY slot returns
// undefined — the designed fail-open to advisory.
export function parseSeveritySummary(envelope: string): SeveritySummary | undefined {
  const lines = envelope.split("\n");
  let terminal = lines.length;
  while (terminal > 0 && lines[terminal - 1].trim() === "") terminal--;
  if (terminal === 0 || lines[terminal - 1].trim() !== TERMINAL_LINE) return undefined;

  let slot = terminal - 1;
  while (slot > 0 && lines[slot - 1].trim() === "") slot--;
  if (slot === 0) return undefined;

  const candidate = lines[slot - 1].trim();
  if (!candidate.startsWith(SEVERITY_PREFIX)) return undefined;

  let parsed: unknown;
  try {
    parsed = JSON.parse(candidate.slice(SEVERITY_PREFIX.length));
  } catch {
    return undefined;
  }
  if (typeof parsed !== "object" || parsed === null) return undefined;
  const record = parsed as Record<string, unknown>;
  if (!isNonNegativeInteger(record.p0Count) || !isNonNegativeInteger(record.p1Count)) return undefined;
  if (typeof record.maxSeverity !== "string") return undefined;
  return { maxSeverity: record.maxSeverity.toUpperCase(), p0Count: record.p0Count, p1Count: record.p1Count };
}

// The SEVERITY line is gate input, not review content: strip it before an
// envelope is echoed into the work prompt (readDocReviewAdvisory) or a
// human-facing synthesis. Whole-line match on the SEVERITY prefix only.
export function stripSeverityLine(text: string): string {
  return text
    .split("\n")
    .filter((line) => !line.trimStart().startsWith(SEVERITY_PREFIX))
    .join("\n")
    .trim();
}
