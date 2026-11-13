import { existsSync } from "node:fs"

type ShellRecord = {
  shell: string
}

type ShellHook = (record: ShellRecord) => void | Promise<void>

type BashShellContext = {
  shell: {
    hook: (name: "create.before", handler: ShellHook) => void | Promise<void>
  }
}

type BashShellPlugin = {
  id: string
  setup: (context: BashShellContext) => void | Promise<void>
}

type BashShellPluginOptions = {
  bashPath: string
  exists: (path: string) => boolean
}

export function createBashShellPlugin({ bashPath, exists }: BashShellPluginOptions): BashShellPlugin {
  return {
    id: "bash-shell",
    async setup(context: BashShellContext): Promise<void> {
      await context.shell.hook("create.before", (record: ShellRecord): void => {
        try {
          if (exists(bashPath)) record.shell = bashPath
        } catch {
          // A failed optional shell check must leave OpenCode's original choice intact.
        }
      })
    },
  }
}

const plugin = createBashShellPlugin({ bashPath: "/bin/bash", exists: existsSync })

export default plugin
