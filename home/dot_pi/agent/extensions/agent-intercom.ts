// @ts-nocheck
import { join } from "node:path"

let intercomExtension: ((pi: any) => any) | undefined
if (process.env.HERDR_ENV === "1") {
  const root = join(
    process.env.HOME ?? "",
    ".local",
    "share",
    "agent-intercom",
    "node_modules",
    "@dataforxyz",
    "agent-intercom-pi",
  )
  const module = await import(join(root, "index.ts"))

  if (typeof module.default !== "function") {
    throw new Error("Agent Intercom Pi package has no default extension export")
  }
  intercomExtension = module.default
}

export default function agentIntercom(pi: any) {
  return intercomExtension?.(pi)
}
