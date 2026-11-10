import { afterEach, expect, test } from "bun:test";
import { cp, mkdtemp, mkdir, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const pluginPath = join(import.meta.dir, "../home/private_dot_config/opencode/plugins/herdr-worktree-identity.ts");

const hookLibrary = join(import.meta.dir, "../home/dot_local/lib/agent-hooks");

const cleanupPaths: string[] = [];

afterEach(async (): Promise<void> => {
  for (const path of cleanupPaths.splice(0)) await rm(path, { recursive: true, force: true });
  delete process.env.HERDR_WORKTREE_IDENTITY_ENGINE;
  delete process.env.HERDR_WORKTREE_IDENTITY_ACTIVE;
});

async function temporaryRoot(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "opencode-worktree-identity-"));

  cleanupPaths.push(root);

  return root;
}

async function recordingEngine(root: string): Promise<string> {
  const engine = join(root, "engine");

  await writeFile(engine, `#!/usr/bin/env bash
mkdir -p "${root}/calls"
call="${root}/calls/$(find "${root}/calls" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
mkdir "$call"
printf '%s\\n' "$@" > "$call/argv"
cat > "$call/stdin"
`);
  await Bun.spawn(["chmod", "+x", engine]).exited;

  return engine;
}

test("OpenCode passes the root session directory and excludes a child session", async (): Promise<void> => {
  // #given
  const root = await temporaryRoot();
  const home = join(root, "home");
  const copy = join(root, "herdr-worktree-identity.ts");
  const engine = await recordingEngine(root);
  await mkdir(join(home, ".local", "lib"), { recursive: true });
  await symlink(hookLibrary, join(home, ".local", "lib", "agent-hooks"));
  await cp(pluginPath, copy);
  process.env.HERDR_WORKTREE_IDENTITY_ENGINE = engine;
  const previousHome = process.env.HOME;

  process.env.HOME = home;
  let promptHook: ((event: { sessionID: string; prompt: { text: string } }) => Promise<void>) | undefined;

  try {
    const { default: plugin } = await import(`${copy}?test=${Date.now()}`);
    await plugin.setup({
      session: {
        hook: async (_name: string, hook: (event: { sessionID: string; prompt: { text: string } }) => Promise<void>): Promise<{ dispose: () => Promise<void> }> => {
          promptHook = hook;

          return { dispose: async (): Promise<void> => {} };
        },
        get: async ({ sessionID }: { sessionID: string }): Promise<{ parentID?: string; location: { directory: string } }> => ({
          parentID: sessionID === "child" ? "root" : undefined,
          location: { directory: sessionID === "child" ? "/worktrees/child" : "/worktrees/opencode-root" },
        }),
      },
    });

    // #when
    await promptHook!({ sessionID: "child", prompt: { text: "Child prompt" } });
    await promptHook!({ sessionID: "root", prompt: { text: "Root prompt" } });
  } finally {
    process.env.HOME = previousHome;
  }

  // #then
  expect(await readdir(join(root, "calls"))).toEqual(["0"]);
  expect((await Bun.file(join(root, "calls", "0", "argv")).text()).trim().split("\n")).toEqual([
    "--agent", "opencode", "--session", "root", "--cwd", "/worktrees/opencode-root",
  ]);
  expect(await Bun.file(join(root, "calls", "0", "stdin")).text()).toBe("Root prompt");
});
