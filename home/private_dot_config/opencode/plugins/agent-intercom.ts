// @ts-nocheck
import type { Plugin } from "@opencode-ai/plugin"
import { join } from "node:path"

let intercomPlugin: Plugin | undefined
if (process.env.HERDR_ENV === "1") {
  const root = join(
    process.env.HOME ?? "",
    ".local",
    "share",
    "agent-intercom",
    "node_modules",
    "@dataforxyz",
    "agent-intercom-opencode",
  )
  const module = await import(join(root, "dist", "plugin.mjs"))

  if (typeof module.default !== "function") {
    throw new Error("Agent Intercom OpenCode server plugin has no default export")
  }
  intercomPlugin = module.default
}

// OpenCode treats every export as a plugin factory, so expose exactly one and
// deliberately omit the package's TUI entrypoint.
export const AgentIntercomPlugin: Plugin = async (input) => intercomPlugin?.(input) ?? {}
