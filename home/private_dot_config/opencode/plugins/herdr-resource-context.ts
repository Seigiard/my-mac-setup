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
      const system = output?.system
      if (!Array.isArray(system)) return

      // Strip our own earlier entry before anything else can return: sessionID
      // is optional in the plugin API, and leaving a stale entry in place would
      // present a previous request's branch as the current one.
      const retained = system.filter((entry) => !generatedContext(entry))
      system.length = 0
      system.push(...retained)

      const sessionID = input?.sessionID
      if (!sessionID) {
        system.push(
          `${HEADING}\nHerdr resource context unavailable: OpenCode did not expose a native session identity. This must not be treated as an empty resource branch.`,
        )
        return
      }

      const context = await queryContext(sessionID)
      if (context === undefined) {
        system.push(
          `${HEADING}\nHerdr resource context unavailable: the shared resource query failed. This must not be treated as an empty resource branch.`,
        )
        return
      }
      if (context !== "") system.push(`${HEADING}\n${context}`)
    },
  }
}
