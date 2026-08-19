// @ts-nocheck
// Type checking is off here for the same reason herdr's own managed extensions
// turn it off: this file is checked out in a plain dotfiles repo with no
// node_modules, and only resolves its imports once deployed under
// ~/.config/opencode/, where opencode's own dependencies live.
import type { Plugin } from "@opencode-ai/plugin"
import { spawn } from "node:child_process"
import { existsSync } from "node:fs"
import path from "node:path"

// opencode adapter for herdr-task-sync.
//
// Sits beside herdr's own ~/.config/opencode/plugins/herdr-agent-state.js,
// which is herdr-managed and must never be edited: its header says to add
// custom plugins beside it instead.
//
// Subagent (task tool) sessions carry a parentID; the main agent session does
// not. `chat.message` alone cannot tell them apart, so child session ids are
// learned from session events and their messages are dropped — otherwise a
// subagent's prompt would rename the pane.
//
// The engine returns after its bounded atomic inbox commit. Model and
// presentation work stays detached inside the engine.

const ENGINE_NAME = "herdr-task-sync"

function enginePath(): string {
  const home = process.env.HOME
  if (home) {
    const local = path.join(home, ".local", "bin", ENGINE_NAME)
    if (existsSync(local)) return local
  }
  return ENGINE_NAME
}

function callEngine(args: string[], prompt: string): Promise<void> {
  return new Promise((resolve) => {
    try {
      const child = spawn(enginePath(), args, {
        stdio: ["pipe", "ignore", "ignore"],
      })
      let settled = false
      const finish = () => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        resolve()
      }
      const timer = setTimeout(() => {
        child.kill()
        finish()
      }, 1000)
      child.on("error", finish)
      child.on("close", finish)
      child.stdin?.on("error", () => {})
      child.stdin?.end(prompt)
    } catch {
      // Naming is best-effort: a missing engine must never break an opencode run.
      resolve()
    }
  })
}

export const HerdrTaskSyncPlugin: Plugin = async () => {
  // HERDR_TASK_SYNC_ACTIVE marks a run started by the engine itself.
  if (process.env.HERDR_ENV !== "1" || process.env.HERDR_TASK_SYNC_ACTIVE) {
    return {}
  }

  const childSessions = new Set<string>()

  return {
    "chat.message": async (input, output) => {
      const sessionID = input?.sessionID
      if (!sessionID || childSessions.has(sessionID)) return

      const parts = Array.isArray(output?.parts) ? output.parts : []
      const prompt = parts
        .filter((part: any) => part?.type === "text" && typeof part.text === "string")
        .map((part: any) => part.text)
        .join("\n")
      if (prompt.trim() === "") return

      await callEngine(["--agent", "opencode", "--session", sessionID], prompt)
    },
    event: async ({ event }) => {
      const info = (event as any)?.properties?.info
      if (info?.id && info.parentID) {
        childSessions.add(info.id)
      }
    },
  }
}
