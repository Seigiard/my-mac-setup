// pi adapter for test-oracle-guard.
//
// Thin wrapper over ~/.local/bin/test-oracle-guard: on edit/write tool calls
// it feeds the proposed new content and target path to the shared engine and
// blocks the call ({ block: true, reason }) when the engine flags an
// unjustified negative assertion in a test file. The engine owns the patterns,
// the test-file filter, and the "oracle:" escape hatch, so all agent clients
// enforce one contract.
//
// Fails open: a missing or broken engine must never block a pi edit.
// @ts-nocheck

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";

const ENGINE_NAME = "test-oracle-guard";

function enginePath(): string | undefined {
  const home = process.env.HOME;
  if (!home) return undefined;
  const local = path.join(home, ".local", "bin", ENGINE_NAME);
  return existsSync(local) ? local : undefined;
}

export default function (pi) {
  pi.on("tool_call", (event) => {
    const toolName = event?.toolName;
    let filePath: string | undefined;
    let content = "";

    if (toolName === "write") {
      filePath = event?.input?.path;
      content = typeof event?.input?.content === "string" ? event.input.content : "";
    } else if (toolName === "edit") {
      filePath = event?.input?.path;
      const edits = Array.isArray(event?.input?.edits) ? event.input.edits : [];
      content = edits
        .map((edit: any) => edit?.newText)
        .filter((text: any) => typeof text === "string" && text !== "")
        .join("\n");
    } else {
      return;
    }

    if (typeof filePath !== "string" || filePath === "" || content === "") return;

    const engine = enginePath();
    if (!engine) return;

    try {
      const result = spawnSync(engine, [filePath], {
        input: content,
        encoding: "utf8",
        timeout: 3000,
      });
      if (result.status === 1 && result.stdout && result.stdout.trim() !== "") {
        return { block: true, reason: result.stdout.trim() };
      }
    } catch {
      // Engine failures (spawn error, timeout) fail open.
    }
  });
}
