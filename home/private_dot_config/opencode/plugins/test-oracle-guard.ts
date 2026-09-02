// @ts-nocheck
// Type checking is off here for the same reason herdr's own managed extensions
// turn it off: this file is checked out in a plain dotfiles repo with no
// node_modules, and only resolves its imports once deployed under
// ~/.config/opencode/, where opencode's own dependencies live.
import type { Plugin } from "@opencode-ai/plugin"
import { spawnSync } from "node:child_process"
import { existsSync } from "node:fs"
import path from "node:path"

// opencode adapter for test-oracle-guard.
//
// Thin wrapper over ~/.local/bin/test-oracle-guard: on edit/write it feeds the
// proposed new content and target path to the shared engine and blocks the
// call (throw) when the engine flags an unjustified negative assertion in a
// test file. The engine owns the patterns, the test-file filter, and the
// "oracle:" escape hatch, so all agent clients enforce one contract.
//
// Fails open: a missing or broken engine must never block an opencode edit.

const ENGINE_NAME = "test-oracle-guard"

function enginePath(): string | undefined {
  const home = process.env.HOME
  if (!home) return undefined
  const local = path.join(home, ".local", "bin", ENGINE_NAME)
  return existsSync(local) ? local : undefined
}

export const TestOracleGuardPlugin: Plugin = async () => {
  return {
    "tool.execute.before": async (input, output) => {
      const tool = input?.tool
      if (tool !== "edit" && tool !== "write") return

      const args = output?.args ?? {}
      const filePath = args.filePath ?? args.file_path
      if (typeof filePath !== "string" || filePath === "") return

      const content = [args.content, args.newString]
        .filter((part: any) => typeof part === "string" && part !== "")
        .join("\n")
      if (content === "") return

      const engine = enginePath()
      if (!engine) return

      try {
        const result = spawnSync(engine, [filePath], {
          input: content,
          encoding: "utf8",
          timeout: 3000,
        })
        if (result.status === 1 && result.stdout && result.stdout.trim() !== "") {
          throw new Error(result.stdout.trim())
        }
      } catch (error: any) {
        if (error instanceof Error && error.message.startsWith("test-oracle-guard:")) {
          throw error
        }
        // Engine failures (spawn error, timeout) fail open.
      }
    },
  }
}
