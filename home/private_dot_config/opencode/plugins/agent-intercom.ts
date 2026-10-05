// @ts-nocheck
import type { Plugin } from "@opencode-ai/plugin"
import { join } from "node:path"

let intercomPlugin: Plugin | undefined

const intercomName = process.env.OPENCODE_INTERCOM_NAME?.trim()

type IntercomClient = Parameters<Plugin>[0]["client"];

function withCloneableResponses(client: IntercomClient): IntercomClient {
  if (!client) return client

  return new Proxy(client, {
    get(target, property) {
      const namespace = target[property]

      if ((property !== "session" && property !== "tui") || !namespace) return namespace

      return new Proxy(namespace, {
        get(namespaceTarget, method) {
          const value = namespaceTarget[method]

          if (!(value instanceof Function)) return value

          return async (...args: any[]) => {
            const result = await value.apply(namespaceTarget, args)
            const response = result?.response

            if (!response?.bodyUsed) return result

            // The SDK has already consumed this body. Preserve response metadata
            // while letting optional plugin diagnostics clone an empty body.
            const cloneableResponse = new Proxy(response, {
              get(responseTarget, responseProperty) {
                if (responseProperty === "clone") {
                  return () => new Response(null, {
                    status: responseTarget.status,
                    statusText: responseTarget.statusText,
                    headers: responseTarget.headers,
                  })
                }

                const responseValue = responseTarget[responseProperty]

                return responseValue instanceof Function
                  ? responseValue.bind(responseTarget)
                  : responseValue
              },
            })

            return { ...result, response: cloneableResponse }
          }
        },
      })
    },
  })
}

if (process.env.HERDR_ENV === "1" && intercomName) {
  const root = join(
    process.env.HOME ?? "",
    ".local",
    "share",
    "agent-intercom",
    "node_modules",
    "@dataforxyz",
    "agent-intercom-opencode",
  )

  try {
    const module = await import(join(root, "dist", "plugin.mjs"))

    if (module.default instanceof Function) intercomPlugin = module.default
  } catch {
    // Intercom is additive; an incomplete optional install must not block OpenCode.
  }
}

// Do not leak this session's alias to nested OpenCode processes.
delete process.env.OPENCODE_INTERCOM_NAME

// OpenCode treats every export as a plugin factory, so expose exactly one and
// deliberately omit the package's TUI entrypoint.
export const AgentIntercomPlugin: Plugin = async (input) => {
  if (!intercomPlugin || !intercomName) return {}

  process.env.OPENCODE_INTERCOM_NAME = intercomName

  try {
    return await intercomPlugin({ ...input, client: withCloneableResponses(input.client) })
  } catch {
    return {}
  } finally {
    delete process.env.OPENCODE_INTERCOM_NAME
  }
}
