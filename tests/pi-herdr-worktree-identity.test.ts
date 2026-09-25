import { afterEach, describe, expect, test } from "bun:test";
import { cp, mkdtemp, mkdir, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const extensionPath = join(import.meta.dir, "../home/dot_pi/agent/extensions/herdr-worktree-identity.ts");
const handoffPath = join(import.meta.dir, "../home/dot_local/lib/agent-hooks/worktree-identity.ts");
const { handoffWorktreeIdentity } = await import(handoffPath);
const cleanupPaths: string[] = [];
let loadCount = 0;

afterEach(async () => {
  for (const path of cleanupPaths.splice(0)) await rm(path, { recursive: true, force: true });
  delete process.env.HERDR_ENV;
  delete process.env.HERDR_WORKTREE_IDENTITY_ACTIVE;
  delete process.env.HERDR_WORKTREE_IDENTITY_ENGINE;
  delete process.env.HERDR_PANE_ID;
  delete process.env.HERDR_WORKSPACE_ID;
});

async function temporaryRoot(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "pi-worktree-identity-test-"));
  cleanupPaths.push(root);
  return root;
}

async function recordingEngine(root: string): Promise<string> {
  const engine = join(root, "recording-engine");
  await writeFile(engine, `#!/usr/bin/env bash
set -eu
call="${root}/call-$$"
mkdir "$call"
printf '%s\\n' "$@" > "$call/argv"
cat > "$call/stdin"
`);
  await Bun.spawn(["chmod", "+x", engine]).exited;
  return engine;
}

async function register() {
  const home = await temporaryRoot();
  await mkdir(join(home, ".local", "lib"), { recursive: true });
  await symlink(join(import.meta.dir, "../home/dot_local/lib/agent-hooks"), join(home, ".local", "lib", "agent-hooks"));
  const copy = join(await temporaryRoot(), `herdr-worktree-identity-${loadCount++}.ts`);
  await cp(extensionPath, copy);

  const previousHome = process.env.HOME;
  process.env.HOME = home;
  const handlers = new Map<string, Function>();
  try {
    const { default: registerWorktreeIdentity } = await import(copy);
    registerWorktreeIdentity({ on: (event: string, handler: Function) => handlers.set(event, handler) } as never);
    return handlers;
  } finally {
    process.env.HOME = previousHome;
  }
}

function context(hasUI = true) {
  return { hasUI, sessionManager: { getSessionId: () => "session-pi" } };
}

describe("Pi worktree identity prompt capture", () => {
  test("shared handoff preserves each adapter identity and stdin-only transport", async () => {
    const root = await temporaryRoot();
    process.env.HERDR_PANE_ID = "pane-shared";
    process.env.HERDR_WORKSPACE_ID = "workspace-shared";
    process.env.HERDR_WORKTREE_IDENTITY_ENGINE = await recordingEngine(root);

    await handoffWorktreeIdentity("pi", "session-pi", "Pi shared sentinel");
    await handoffWorktreeIdentity("opencode", "session-opencode", "OpenCode shared sentinel");

    const calls = (await readdir(root)).filter((entry) => entry.startsWith("call-"));
    expect(calls).toHaveLength(2);
    const records = await Promise.all(
      calls.map(async (entry) => {
        const call = join(root, entry);
        return {
          argv: (await Bun.file(join(call, "argv")).text()).trim().split("\n"),
          stdin: await Bun.file(join(call, "stdin")).text(),
        };
      }),
    );
    expect(records).toContainEqual({
      argv: ["--agent", "pi", "--session", "session-pi", "--pane", "pane-shared", "--workspace", "workspace-shared"],
      stdin: "Pi shared sentinel",
    });
    expect(records).toContainEqual({
      argv: [
        "--agent",
        "opencode",
        "--session",
        "session-opencode",
        "--pane",
        "pane-shared",
        "--workspace",
        "workspace-shared",
      ],
      stdin: "OpenCode shared sentinel",
    });
  });

  test("registers before_agent_start and hands the prompt to the engine on stdin only", async () => {
    const root = await temporaryRoot();
    process.env.HERDR_ENV = "1";
    process.env.HERDR_PANE_ID = "pane-pi";
    process.env.HERDR_WORKSPACE_ID = "workspace-pi";
    process.env.HERDR_WORKTREE_IDENTITY_ENGINE = await recordingEngine(root);
    const handlers = await register();

    const handler = handlers.get("before_agent_start");
    expect(handler).toBeTypeOf("function");
    await handler!({ prompt: "Pi stdin-only sentinel" }, context());

    const calls = (await readdir(root)).filter((entry) => entry.startsWith("call-"));
    expect(calls).toHaveLength(1);
    const call = join(root, calls[0]);
    expect(await Bun.file(join(call, "stdin")).text()).toBe("Pi stdin-only sentinel");
    // The exact flag list, not a substring: "pi" also matches the pane and
    // workspace ids in the same argv, so it stays satisfied when --agent
    // carries the wrong client. The list also shows the prompt never becomes
    // an argument, where another process could read it.
    expect((await Bun.file(join(call, "argv")).text()).trim().split("\n")).toEqual([
      "--agent",
      "pi",
      "--session",
      "session-pi",
      "--pane",
      "pane-pi",
      "--workspace",
      "workspace-pi",
    ]);
  });

  test("does not register outside herdr", async () => {
    const root = await temporaryRoot();
    process.env.HERDR_WORKTREE_IDENTITY_ENGINE = await recordingEngine(root);

    const handlers = await register();

    expect(handlers.size).toBe(0);
    expect((await readdir(root)).filter((entry) => entry.startsWith("call-"))).toEqual([]);
  });

  test("declines to capture a session with no UI", async () => {
    const root = await temporaryRoot();
    process.env.HERDR_ENV = "1";
    process.env.HERDR_WORKTREE_IDENTITY_ENGINE = await recordingEngine(root);
    const handlers = await register();
    // Without this, a registration that never happened produces the same empty
    // root as a handler that declined, so the two are indistinguishable.
    expect(handlers.size).toBe(1);

    await handlers.get("before_agent_start")!({ prompt: "headless" }, context(false));

    expect((await readdir(root)).filter((entry) => entry.startsWith("call-"))).toEqual([]);
  });

  test("does not register during naming re-entry", async () => {
    const root = await temporaryRoot();
    process.env.HERDR_ENV = "1";
    process.env.HERDR_WORKTREE_IDENTITY_ACTIVE = "1";
    process.env.HERDR_WORKTREE_IDENTITY_ENGINE = await recordingEngine(root);

    const handlers = await register();

    expect(handlers.size).toBe(0);
    expect((await readdir(root)).filter((entry) => entry.startsWith("call-"))).toEqual([]);
  });
});
