// The run log prints a check mark for every node that finished without
// throwing. A gate node that decided "failed" finished without throwing, so it
// looked identical to a green one, and the verdict was never printed at all —
// operators approved red gates believing they were confirming green stages
// (run-1786718288581). The gate now announces itself, once, when it executes.
// Pure string building so the wording is testable without a run.

export type GateNext = "waive" | "extra-attempt" | "abort-only";

const RULE = "─".repeat(72);

// What the operator's approve/deny actually does, spelled out. The trap was
// never the missing verdict alone: "approve" at a failed work gate means RETRY
// THE STAGE, which reads as "continue" to anyone who has not read stageBlock.
const NEXT_ACTION: Record<GateNext, string> = {
  waive: "approve = WAIVE this gate and CONTINUE the pipeline | deny = abort the run",
  "extra-attempt": "approve = ONE more attempt of this stage (it will be re-run and re-paid) | deny = abort the run",
  "abort-only": "approve = STOP the run and write a report (no further stages) | deny = fail the run",
};

export function gateAnnouncement(stage: string, state: string, reasons: string, next: GateNext | null): string {
  if (state === "green") return `GATE ${stage}: GREEN`;
  const lines = [RULE, `GATE ${stage}: ${state.toUpperCase()} — the run is about to pause for your decision`];
  for (const reason of splitReasons(reasons)) {
    const [first, ...rest] = reason.split("\n");
    lines.push(`  why: ${first}`);
    for (const line of rest) lines.push(`       ${line}`);
  }
  if (next !== null) lines.push(`  ${NEXT_ACTION[next]}`);
  lines.push(RULE);
  return lines.join("\n");
}

// Reasons arrive joined with "; ". One of them carries a multi-line command
// tail, which stays attached to its own reason as continuation lines — marking
// every tail line as a separate "why" buries the one-line reason above it.
function splitReasons(reasons: string): string[] {
  if (reasons.trim() === "") return ["(no reason recorded — this is itself a defect, please report it)"];
  return reasons
    .split("; ")
    .map((r) => r.trim())
    .filter((r) => r !== "");
}
