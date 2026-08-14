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
  const maxSeverity = record.maxSeverity.toUpperCase();
  // Cross-field consistency: a schema-valid but self-contradictory summary
  // ({maxSeverity:"P0", p0Count:0} — a plausible LLM counting slip) must not
  // reach the gate as trustworthy input. The gate blocks on p0Count alone, so
  // an inconsistent pair would silently pass as green. Inconsistent or unknown
  // maxSeverity → undefined → the leg-availability-only advisory path.
  if (!["P0", "P1", "P2", "P3", "NONE"].includes(maxSeverity)) return undefined;
  const consistent =
    record.p0Count > 0
      ? maxSeverity === "P0"
      : record.p1Count > 0
        ? maxSeverity === "P1"
        : maxSeverity !== "P0" && maxSeverity !== "P1";
  if (!consistent) return undefined;
  return { maxSeverity, p0Count: record.p0Count, p1Count: record.p1Count };
}

// The SEVERITY line is gate input, not review content: strip it before an
// envelope is echoed into the work prompt (readDocReviewAdvisory) or a
// human-facing synthesis.
//
// Only the machine line is removed, and the machine line is the one in the
// protected slot — the same position parseSeveritySummary reads. Matching the
// prefix anywhere silently truncated review prose that legitimately began with
// "SEVERITY:", which is prose a review leg has every reason to write when it
// discusses the gate's own contract.
//
// Two accepted shapes: the slot before the terminal `Review complete` line, and
// the last non-empty line when the envelope has no terminal line. The second is
// kept because an envelope missing its terminal line still parses as advisory,
// and its machine line would otherwise reach the work agent as review content.
//
// Position alone is not enough, because prose can land in the slot too. The
// line must also carry a JSON object after the prefix. Between the two failure
// modes that leaves, letting a malformed machine line through is noise in a
// prompt, while eating a prose line loses review content the work agent needed.
export function stripSeverityLine(text: string): string {
  const lines = text.split("\n");
  let last = lines.length;
  while (last > 0 && lines[last - 1].trim() === "") last--;
  if (last === 0) return text.trim();

  let slot = last;
  if (lines[last - 1].trim() === TERMINAL_LINE) {
    slot = last - 1;
    while (slot > 0 && lines[slot - 1].trim() === "") slot--;
    if (slot === 0) return text.trim();
  }

  if (!isSeverityMachineLine(lines[slot - 1].trim())) return text.trim();
  return [...lines.slice(0, slot - 1), ...lines.slice(slot)].join("\n").trim();
}

function isSeverityMachineLine(line: string): boolean {
  if (!line.startsWith(SEVERITY_PREFIX)) return false;
  try {
    const parsed: unknown = JSON.parse(line.slice(SEVERITY_PREFIX.length));
    return typeof parsed === "object" && parsed !== null;
  } catch {
    return false;
  }
}
