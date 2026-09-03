// @ts-nocheck
// OpenCode prompt adapter for herdr-worktree-identity. The engine detaches its
// model worker before this foreground handshake resolves.
import type { Plugin } from "@opencode-ai/plugin"
import { spawn } from "node:child_process"
import { existsSync } from "node:fs"
import path from "node:path"

const ENGINE_NAME = "herdr-worktree-identity"
const HANDSHAKE_TIMEOUT_MS = 1000

function enginePath(): string {
  const configured = process.env.HERDR_WORKTREE_IDENTITY_ENGINE
  if (configured) return configured
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
      const child = spawn(enginePath(), args, { stdio: ["pipe", "ignore", "ignore"] })
      let settled = false
      const finish = () => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        resolve()
      }
      const timer = setTimeout(() => {
        child.stdin?.destroy()
        child.kill("SIGTERM")
        finish()
      }, HANDSHAKE_TIMEOUT_MS)
      timer.unref?.()
      child.once("error", finish)
      child.once("close", finish)
      child.stdin?.once("error", () => {})
      child.stdin?.end(prompt)
    } catch {
      resolve()
    }
  })
}

function engineArgs(sessionID: string): string[] {
  const args = ["--agent", "opencode", "--session", sessionID]
  if (process.env.HERDR_PANE_ID) args.push("--pane", process.env.HERDR_PANE_ID)
  if (process.env.HERDR_WORKSPACE_ID) args.push("--workspace", process.env.HERDR_WORKSPACE_ID)
  return args
}

export const HerdrWorktreeIdentityPlugin: Plugin = async () => {
  if (process.env.HERDR_ENV !== "1" || process.env.HERDR_WORKTREE_IDENTITY_ACTIVE) return {}

  const childSessions = new Set<string>()
  return {
    "chat.message": async (input, output) => {
      const sessionID = input?.sessionID
      if (!sessionID || childSessions.has(sessionID)) return
      const prompt = (Array.isArray(output?.parts) ? output.parts : [])
        .filter((part: any) => part?.type === "text" && typeof part.text === "string")
        .map((part: any) => part.text)
        .join("\n")
      if (prompt.trim() !== "") await callEngine(engineArgs(sessionID), prompt)
    },
    event: async ({ event }) => {
      const type = (event as any)?.type
      const info = (event as any)?.properties?.info
      if (type === "session.deleted" && info?.id) childSessions.delete(info.id)
      else if (info?.id && info.parentID) childSessions.add(info.id)
    },
  }
}
