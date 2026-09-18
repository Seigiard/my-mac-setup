// @ts-nocheck
// OpenCode model-request adapter for the shared Herdr resource projection.
import type { Plugin } from "@opencode-ai/plugin"
import { execFile } from "node:child_process"
import { homedir } from "node:os"
import { join } from "node:path"

const HEADING = "## Herdr Agent Resource Context (generated)"
const RESOURCE_CLI =
  process.env.HERDR_RESOURCE_CONTEXT_CLI ??
  join(process.env.HOME || homedir(), ".local", "bin", "herdr-resource-tree")

function queryContext(sessionID: string): Promise<string | undefined> {
  return new Promise((resolve) => {
    execFile(
      RESOURCE_CLI,
      ["--context", "--caller-agent", "opencode", "--caller-session-id", sessionID],
      { encoding: "utf8", maxBuffer: 64 * 1024 },
      (error, stdout) => {
        if (error) return resolve(undefined)
        resolve(stdout.replace(/\r?\n$/, ""))
      },
    )
  })
}

function generatedContext(entry: unknown): boolean {
  return typeof entry === "string" && (entry === HEADING || entry.startsWith(`${HEADING}\n`))
}

export const HerdrResourceContextPlugin: Plugin = async () => {
  if (process.env.HERDR_ENV !== "1") return {}

  return {
    "experimental.chat.system.transform": async (input, output) => {
      const sessionID = input?.sessionID
      const system = output?.system
      if (!sessionID || !Array.isArray(system)) return

      const context = await queryContext(sessionID)
      if (context === undefined) return

      const retained = system.filter((entry) => !generatedContext(entry))
      system.length = 0
      system.push(...retained)
      if (context !== "") system.push(`${HEADING}\n${context}`)
    },
  }
}
