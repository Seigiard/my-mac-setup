// Claude Code transport for the shared dispatch core.
//
// stdin is Claude's PreToolUse hook JSON ({tool_name, tool_input}); stdout is
// the `hookSpecificOutput` envelope the four hand-written hooks emitted before
// this consolidation, byte-for-byte in shape (two-space JSON, trailing
// newline) so the pinned assertions still describe the contract.
//
// The exit status is always 0. A deny travels in the JSON body, never in the
// status, and every failure path — unreadable stdin, malformed JSON, a core
// that will not import, a policy that throws — falls open (R4).

import { readFileSync } from "node:fs";

import type { Decision, ToolEventValue } from "./types.ts";

const CLIENT = "claude";

type SetupTools = typeof import("./worktree-setup.ts");

type DispatchFn = (client: string, rawEvent: ToolEventValue, options?: { setup?: ReturnType<SetupTools["readSetupObservation"]>["state"] }) => Decision;

// A dynamic import in try/catch rather than a static one: R4 names a failed
// core import as a path that must let the tool call through, and a static
// import failure would put a stack trace on stderr for every matched call.
let dispatchFn: DispatchFn | undefined;

let setupTools: SetupTools | undefined;

try {
  ({ dispatch: dispatchFn } = await import("./index.ts"));
} catch {
  dispatchFn = undefined;
}

try {
  setupTools = await import("./worktree-setup.ts");
} catch {
  setupTools = undefined;
}

export function renderDecision(decision: Decision): string | undefined {
  if (decision.verdict === "block") {
    return JSON.stringify(
      {
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: decision.reason,
        },
      },
      null,
      2,
    );
  }

  if (decision.verdict === "context") {
    return JSON.stringify(
      {
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          additionalContext: decision.text,
        },
      },
      null,
      2,
    );
  }

  return undefined;
}

export function main(): number {
  if (!dispatchFn) return 0;

  let raw: ToolEventValue;

  try {
    raw = JSON.parse(readFileSync(0, "utf8"));
  } catch {
    return 0;
  }

  let rendered: string | undefined;

  try {
    // SAFETY: Claude's hook contract supplies cwd as a string in the parsed event.
    const cwd = (raw as { cwd?: string }).cwd;
    const observation = setupTools?.readSetupObservation(cwd) ?? { state: { status: "absent" } };
    const decision = dispatchFn(CLIENT, raw, { setup: observation.state });

    if (setupTools !== undefined && !setupTools.shouldDeliverSetupDecision(observation, decision)) return 0;

    rendered = renderDecision(decision);
  } catch {
    return 0;
  }

  if (rendered !== undefined) process.stdout.write(`${rendered}\n`);

  return 0;
}

if (import.meta.main) process.exit(main());
