// pi adapter for zsh-reserved-name-guard.
//
// Thin wrapper over ~/.local/bin/zsh-reserved-name-guard: on a bash tool call
// it feeds the proposed command to the shared engine and blocks the call
// ({ block: true, reason }) when the command assigns to a parameter zsh
// reserves. The engine owns the name list, the command-position rule, the
// heredoc skip, and the "zsh-ok:" escape hatch, so all agent clients enforce
// one contract.
//
// Fails open: a missing or broken engine must never block a pi command.
// @ts-nocheck

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";

const ENGINE_NAME = "zsh-reserved-name-guard";

function enginePath(): string | undefined {
  const home = process.env.HOME;
  if (!home) return undefined;
  const local = path.join(home, ".local", "bin", ENGINE_NAME);
  return existsSync(local) ? local : undefined;
}

export default function (pi) {
  pi.on("tool_call", (event) => {
    if (event?.toolName !== "bash") return;

    const command = event?.input?.command;
    if (typeof command !== "string" || command === "") return;

    const engine = enginePath();
    if (!engine) return;

    try {
      const result = spawnSync(engine, [], {
        input: command,
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
