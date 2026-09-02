// @ts-nocheck
// Type checking is off here for the same reason herdr's own managed extensions
// turn it off: this file is checked out in a plain dotfiles repo with no
// node_modules, and only resolves its imports once deployed under
// ~/.config/opencode/, where opencode's own dependencies live.
import type { Plugin } from "@opencode-ai/plugin"
import { spawnSync } from "node:child_process"
import { existsSync } from "node:fs"
import path from "node:path"

// opencode adapter for zsh-reserved-name-guard.
//
// Thin wrapper over ~/.local/bin/zsh-reserved-name-guard: on a bash call it
// feeds the proposed command to the shared engine and blocks the call (throw)
// when the command assigns to a parameter zsh reserves. opencode has no shell
// config key, so its bash tool follows process.env.SHELL — zsh here — and
// `status=$?` both fails and corrupts the exit code the agent then reports.
// The engine owns the name list, the command-position rule, the heredoc skip,
// and the "zsh-ok:" escape hatch, so all agent clients enforce one contract.
//
// Fails open: a missing or broken engine must never block an opencode command.

const ENGINE_NAME = "zsh-reserved-name-guard"

function enginePath(): string | undefined {
  const home = process.env.HOME
  if (!home) return undefined
  const local = path.join(home, ".local", "bin", ENGINE_NAME)
  return existsSync(local) ? local : undefined
}

export const ZshReservedNameGuardPlugin: Plugin = async () => {
  return {
    "tool.execute.before": async (input, output) => {
      if (input?.tool !== "bash") return

      const command = (output?.args ?? {}).command
      if (typeof command !== "string" || command === "") return

      const engine = enginePath()
      if (!engine) return

      try {
        const result = spawnSync(engine, [], {
          input: command,
          encoding: "utf8",
          timeout: 3000,
        })
        if (result.status === 1 && result.stdout && result.stdout.trim() !== "") {
          throw new Error(result.stdout.trim())
        }
      } catch (error: any) {
        if (error instanceof Error && error.message.startsWith("zsh-reserved-name-guard:")) {
          throw error
        }
        // Engine failures (spawn error, timeout) fail open.
      }
    },
  }
}
