import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const extensionPath = join(import.meta.dir, "../home/dot_pi/agent/extensions/herdr-worktree-identity.ts");
const { default: registerWorktreeIdentity } = await import(extensionPath);
const cleanupPaths: string[] = [];

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

function register() {
  const handlers = new Map<string, Function>();
  registerWorktreeIdentity({ on: (event: string, handler: Function) => handlers.set(event, handler) } as never);
  return handlers;
}

function context(hasUI = true) {
  return { hasUI, sessionManager: { getSessionId: () => "session-pi" } };
}

describe("Pi worktree identity prompt capture", () => {
  test("registers before_agent_start and hands off a stdin-only prompt while derivation remains pending", async () => {
    const root = await temporaryRoot();
    process.env.HERDR_ENV = "1";
    process.env.HERDR_PANE_ID = "pane-pi";
    process.env.HERDR_WORKSPACE_ID = "workspace-pi";
    process.env.HERDR_WORKTREE_IDENTITY_ENGINE = await stubEngine(root);
    const handlers = register();

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
    const outside = register();
    expect(outside.size).toBe(0);

    process.env.HERDR_ENV = "1";
    const headless = register();
    await headless.get("before_agent_start")?.({ prompt: "headless" }, context(false));

    process.env.HERDR_WORKTREE_IDENTITY_ACTIVE = "1";
    const reentry = register();
    expect(reentry.size).toBe(0);
    expect((await readdir(root)).filter((entry) => entry.startsWith("call-")).length).toBe(0);
  });
});
