import { describe, expect, test } from "bun:test";
import { join } from "node:path";

const PLUGIN_PATH = join(import.meta.dir, "../home/private_dot_config/opencode/plugins/bash-shell.ts");

type ShellRecord = {
  command: string;
  cwd: string;
  timeout: number;
  shell: string;
  env: Record<string, string>;
};

type ShellHook = (record: ShellRecord) => void | Promise<void>;

type BashShellPlugin = {
  setup: (context: { shell: { hook: (name: string, handler: ShellHook) => void | Promise<void> } }) => void | Promise<void>;
};

type BashShellPluginModule = {
  default?: BashShellPlugin;
  createBashShellPlugin?: (options: { bashPath: string; exists: (path: string) => boolean }) => BashShellPlugin;
};

async function loadPlugin(): Promise<BashShellPluginModule | undefined> {
  try {
    // SAFETY: the test owns this plugin boundary and validates its default export and factory before use.
    return (await import(PLUGIN_PATH)) as BashShellPluginModule;
  } catch {
    return undefined;
  }
}

const pluginModule = await loadPlugin();

function requirePlugin(): BashShellPluginModule {
  expect(pluginModule).toBeDefined();

  if (pluginModule === undefined) throw new Error("OpenCode bash-shell plugin is unavailable");

  return pluginModule;
}

async function createBeforeHook(plugin: BashShellPlugin): Promise<ShellHook> {
  let hook: ShellHook | undefined;

  await plugin.setup({
    shell: {
      hook: (name, handler) => {
        if (name === "create.before") hook = handler;
      },
    },
  });

  if (hook === undefined) throw new Error("OpenCode shell create.before hook is unavailable");

  return hook;
}

function requireDefaultPlugin(): BashShellPlugin {
  const plugin = requirePlugin().default;
  expect(plugin).toBeDefined();

  if (plugin === undefined) throw new Error("OpenCode bash-shell plugin default export is unavailable");

  return plugin;
}

function requireFactory(): NonNullable<BashShellPluginModule["createBashShellPlugin"]> {
  const factory = requirePlugin().createBashShellPlugin;
  expect(factory).toBeTypeOf("function");

  if (factory === undefined) throw new Error("OpenCode bash-shell plugin factory is unavailable");

  return factory;
}

describe("OpenCode bash shell plugin", () => {
  test("registers the create.before shell hook", async () => {
    // #given the plugin's default export and an OpenCode V2 shell host
    const names: string[] = [];

    // #when the host initializes the plugin
    await requireDefaultPlugin().setup({
      shell: {
        hook: (name) => {
          names.push(name);
        },
      },
    });

    // #then it registers the documented shell-spawn boundary
    expect(names).toEqual(["create.before"]);
  });

  test("changes a zsh shell record to bash without changing its other fields", async () => {
    // #given the registered handler and an OpenCode record that would spawn zsh
    const hook = await createBeforeHook(requireDefaultPlugin());

    const record: ShellRecord = {
      command: "git status",
      cwd: "/workspace/project",
      timeout: 30_000,
      shell: "/bin/zsh",
      env: { TERM: "xterm-256color" },
    };

    // #when OpenCode prepares the process
    await hook(record);

    // #then bash is selected and the host-owned record fields survive unchanged
    expect(record).toEqual({
      command: "git status",
      cwd: "/workspace/project",
      timeout: 30_000,
      shell: "/bin/bash",
      env: { TERM: "xterm-256color" },
    });
  });

  test("leaves an existing bash shell record unchanged", async () => {
    // #given an OpenCode record that already selects bash
    const hook = await createBeforeHook(requireDefaultPlugin());

    const record: ShellRecord = {
      command: "git status",
      cwd: "/workspace/project",
      timeout: 30_000,
      shell: "/bin/bash",
      env: { TERM: "xterm-256color" },
    };

    // #when OpenCode prepares the process
    await hook(record);

    // #then the complete record remains unchanged
    expect(record).toEqual({
      command: "git status",
      cwd: "/workspace/project",
      timeout: 30_000,
      shell: "/bin/bash",
      env: { TERM: "xterm-256color" },
    });
  });

  test("leaves the record unchanged when the configured bash path is unavailable", async () => {
    // #given a plugin whose injected file check reports no bash executable
    const plugin = requireFactory()({ bashPath: "/missing/bash", exists: () => false });
    const hook = await createBeforeHook(plugin);

    const record: ShellRecord = {
      command: "git status",
      cwd: "/workspace/project",
      timeout: 30_000,
      shell: "/bin/zsh",
      env: { TERM: "xterm-256color" },
    };

    // #when OpenCode prepares the process
    await hook(record);

    // #then the host's original shell selection remains intact
    expect(record).toEqual({
      command: "git status",
      cwd: "/workspace/project",
      timeout: 30_000,
      shell: "/bin/zsh",
      env: { TERM: "xterm-256color" },
    });
  });
});
