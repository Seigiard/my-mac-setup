// @ts-nocheck
// Type checking is off: this file is checked out in a plain dotfiles repo with no
// node_modules, and only resolves its imports once deployed under ~/.config/opencode/,
// where opencode's own dependencies live.
import { execFile } from "node:child_process"
import { homedir } from "node:os"
import { join } from "node:path"
import type { SystemPart } from "@opencode/ai"
import type { Plugin as OpenCodePlugin } from "@opencode/plugin"
import type { SessionRequest } from "@opencode/plugin/promise/session"

const HEADING = "## Herdr Agent Resource Context (generated)"

const HOOKS = ["context", "compaction", "generate", "title"]

const RESOURCE_CLI =
  process.env.HERDR_RESOURCE_CONTEXT_CLI ??
  join(process.env.HOME || homedir(), ".local", "bin", "herdr-resource-tree")

function queryContext(sessionID: string): Promise<string | undefined> {
  return new Promise((resolve) => {
    execFile(
      RESOURCE_CLI,
      ["--context", "--caller-agent", "opencode", "--caller-session-id", sessionID],
      { encoding: "utf8", maxBuffer: 64 * 1024 },
      (error, stdout) => resolve(error ? undefined : stdout.replace(/\r?\n$/, "")),
    )
  })
}

function generatedContext(text: string): boolean {
  return text === HEADING || text.startsWith(`${HEADING}\n`)
}

function unavailable(reason: string): string {
  return `${HEADING}\nHerdr resource context unavailable: ${reason}. This must not be treated as an empty resource branch.`
}

async function resourceContext(sessionID?: string): Promise<string | undefined> {
  if (!sessionID) return unavailable("OpenCode did not expose a native session identity")

  const context = await queryContext(sessionID)

  if (context === undefined) return unavailable("the shared resource query failed")

  if (context !== "") return `${HEADING}\n${context}`
}

const plugin = {
  id: "herdr-resource-context",
  async setup(ctx) {
    if (process.env.HERDR_ENV !== "1") return

    const inject = async (request: SessionRequest) => {
      // Strip before querying so a failed lookup cannot present a prior branch as current.
      const retained = request.system.filter((part) => !generatedContext(part.text))
      request.system.length = 0
      request.system.push(...retained)

      const context = await resourceContext(request.sessionID)

      if (context) request.system.push({ type: "text", text: context } satisfies SystemPart)
    }

    await Promise.all(HOOKS.map((hook) => ctx.session.hook(hook, inject)))
  },
}

export default plugin
