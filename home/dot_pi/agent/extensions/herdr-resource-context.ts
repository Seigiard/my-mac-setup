// @ts-nocheck
// Pi model-request adapter for the shared Herdr resource projection.
import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

const HEADING = "## Herdr Agent Resource Context (generated)";
const START = "<!-- herdr-resource-context:start -->";
const END = "<!-- herdr-resource-context:end -->";
const RESOURCE_CLI =
  process.env.HERDR_RESOURCE_CONTEXT_CLI ??
  join(process.env.HOME || homedir(), ".local", "bin", "herdr-resource-tree");

function sessionId(ctx: any): string | undefined {
  try {
    const id = ctx?.sessionManager?.getSessionId?.();
    return typeof id === "string" && id.length > 0 ? id : undefined;
  } catch {
    return undefined;
  }
}

function queryContext(id: string): Promise<string | undefined> {
  return new Promise((resolve) => {
    execFile(
      RESOURCE_CLI,
      ["--context", "--caller-agent", "pi", "--caller-session-id", id],
      { encoding: "utf8", maxBuffer: 64 * 1024 },
      (error, stdout) => {
        if (error) return resolve(undefined);
        resolve(stdout.replace(/\r?\n$/, ""));
      },
    );
  });
}

function withoutGeneratedContext(systemPrompt: string): string {
  let result = systemPrompt;
  let start = result.indexOf(START);
  while (start !== -1) {
    const end = result.indexOf(END, start + START.length);
    if (end === -1) break;
    const blockStart = start >= 2 && result.slice(start - 2, start) === "\n\n" ? start - 2 : start;
    result = result.slice(0, blockStart) + result.slice(end + END.length);
    start = result.indexOf(START);
  }
  return result;
}

function withGeneratedContext(systemPrompt: string, context: string): string {
  const block = `${START}\n${HEADING}\n${context}\n${END}`;
  return systemPrompt === "" ? block : `${systemPrompt}\n\n${block}`;
}

function unavailable(systemPrompt: string, reason: string): { systemPrompt: string } {
  return {
    systemPrompt: withGeneratedContext(
      systemPrompt,
      `Herdr resource context unavailable: ${reason}. This must not be treated as an empty resource branch.`,
    ),
  };
}

export default function registerResourceContext(pi: any): void {
  if (process.env.HERDR_ENV !== "1") return;

  let activeSessionId: string | undefined;

  pi.on("session_start", (_event: any, ctx: any) => {
    activeSessionId = sessionId(ctx);
  });

  pi.on("before_agent_start", async (event: any, ctx: any) => {
    const systemPrompt = withoutGeneratedContext(typeof event?.systemPrompt === "string" ? event.systemPrompt : "");
    const requestSessionId = sessionId(ctx);
    if (!activeSessionId || !requestSessionId) {
      return unavailable(systemPrompt, "Pi did not expose a native session identity");
    }
    if (requestSessionId !== activeSessionId) {
      return unavailable(systemPrompt, "Pi session identity changed before context projection");
    }
    const context = await queryContext(requestSessionId);
    if (context === undefined) {
      return unavailable(systemPrompt, "the shared resource query failed");
    }
    if (context === "") {
      return systemPrompt === event.systemPrompt ? undefined : { systemPrompt };
    }
    return { systemPrompt: withGeneratedContext(systemPrompt, context) };
  });
}
