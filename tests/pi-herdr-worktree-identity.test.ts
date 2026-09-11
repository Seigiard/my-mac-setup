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

async function waitFor(path: string): Promise<void> {
  for (let attempt = 0; attempt < 3000; attempt += 1) {
    if (await Bun.file(path).exists()) return;
    await Bun.sleep(1);
  }
  throw new Error(`timed out waiting for ${path}`);
}

async function stubEngine(root: string): Promise<string> {
  const engine = join(root, "engine");
  await writeFile(engine, `#!/usr/bin/env bash
set -eu
call="${root}/call-$$"
mkdir "$call"
printf '%s\\n' "$@" > "$call/argv"
cat > "$call/stdin"
: > "$call/ready"
( while [ ! -e "${root}/release" ]; do sleep 0.01; done; : > "$call/released" ) &
exit 0
`);
  await Bun.spawn(["chmod", "+x", engine]).exited;
  return engine;
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

  test("registers before_agent_start and hands off a stdin-only prompt while derivation remains pending", async () => {
    const root = await temporaryRoot();
    process.env.HERDR_ENV = "1";
    process.env.HERDR_PANE_ID = "pane-pi";
    process.env.HERDR_WORKSPACE_ID = "workspace-pi";
    process.env.HERDR_WORKTREE_IDENTITY_ENGINE = await stubEngine(root);
    const handlers = await register();

    const handler = handlers.get("before_agent_start");
    expect(handler).toBeDefined();
    await handler({ prompt: "Pi stdin-only sentinel" }, context());

    const calls = (await readdir(root)).filter((entry) => entry.startsWith("call-"));
    expect(calls).toHaveLength(1);
    const call = join(root, calls[0]);
    expect(await Bun.file(join(call, "stdin")).text()).toBe("Pi stdin-only sentinel");
    expect(await Bun.file(join(call, "argv")).text()).toContain("pi");
    expect(await Bun.file(join(call, "argv")).text()).not.toContain("Pi stdin-only sentinel");
    await waitFor(join(call, "ready"));
    expect(await Bun.file(join(call, "released")).exists()).toBe(false);
    await writeFile(join(root, "release"), "");
    await waitFor(join(call, "released"));
  });

  test("does not capture outside herdr, without session UI, or during naming re-entry", async () => {
    const root = await temporaryRoot();
    process.env.HERDR_WORKTREE_IDENTITY_ENGINE = await stubEngine(root);
    const outside = await register();
    expect(outside.size).toBe(0);

    process.env.HERDR_ENV = "1";
    const headless = await register();
    await headless.get("before_agent_start")?.({ prompt: "headless" }, context(false));

    process.env.HERDR_WORKTREE_IDENTITY_ACTIVE = "1";
    const reentry = await register();
    expect(reentry.size).toBe(0);
    expect((await readdir(root)).filter((entry) => entry.startsWith("call-")).length).toBe(0);
  });
});
