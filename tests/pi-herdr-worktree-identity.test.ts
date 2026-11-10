import { afterEach, expect, test } from "bun:test";
import { cp, mkdtemp, mkdir, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const extensionPath = join(import.meta.dir, "../home/dot_pi/private_agent/extensions/herdr-worktree-identity.ts");

const hookLibrary = join(import.meta.dir, "../home/dot_local/lib/agent-hooks");

const cleanupPaths: string[] = [];

type PromptEvent = { prompt?: string };

type PiContext = {
  hasUI: boolean;
  cwd: string;
  sessionManager: { getSessionId: () => string };
};

type PiHandler = (event: PromptEvent, context: PiContext) => Promise<void>;

afterEach(async (): Promise<void> => {
  for (const path of cleanupPaths.splice(0)) await rm(path, { recursive: true, force: true });
  delete process.env.HERDR_WORKTREE_IDENTITY_ENGINE;
  delete process.env.HERDR_WORKTREE_IDENTITY_ACTIVE;
});

async function temporaryRoot(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "pi-worktree-identity-"));

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

test("Pi passes its session directory to the engine without a Herdr environment gate", async (): Promise<void> => {
  // #given
  const root = await temporaryRoot();
  const home = join(root, "home");
  const copy = join(root, "herdr-worktree-identity.ts");
  const engine = await recordingEngine(root);
  await mkdir(join(home, ".local", "lib"), { recursive: true });
  await symlink(hookLibrary, join(home, ".local", "lib", "agent-hooks"));
  await cp(extensionPath, copy);
  process.env.HERDR_WORKTREE_IDENTITY_ENGINE = engine;
  const previousHome = process.env.HOME;
  process.env.HOME = home;
  const handlers = new Map<string, PiHandler>();

  try {
    const { default: registerWorktreeIdentity } = await import(`${copy}?test=${Date.now()}`);
    registerWorktreeIdentity({ on: (event: string, handler: PiHandler): void => { handlers.set(event, handler); } });

    // #when
    await handlers.get("before_agent_start")!({ prompt: "Pi directory sentinel" }, {
      hasUI: true,
      cwd: "/worktrees/pi-checkout",
      sessionManager: { getSessionId: (): string => "session-pi" },
    });
  } finally {
    process.env.HOME = previousHome;
  }

  // #then
  expect(await readdir(join(root, "calls"))).toEqual(["0"]);
  expect((await Bun.file(join(root, "calls", "0", "argv")).text()).trim().split("\n")).toEqual([
    "--agent", "pi", "--session", "session-pi", "--cwd", "/worktrees/pi-checkout",
  ]);
  expect(await Bun.file(join(root, "calls", "0", "stdin")).text()).toBe("Pi directory sentinel");
});

test("Pi skips a headless session and hands off the interactive control", async (): Promise<void> => {
  // #given
  const root = await temporaryRoot();
  const home = join(root, "home");
  const copy = join(root, "herdr-worktree-identity.ts");
  const engine = await recordingEngine(root);
  await mkdir(join(home, ".local", "lib"), { recursive: true });
  await symlink(hookLibrary, join(home, ".local", "lib", "agent-hooks"));
  await cp(extensionPath, copy);
  process.env.HERDR_WORKTREE_IDENTITY_ENGINE = engine;
  const previousHome = process.env.HOME;
  process.env.HOME = home;
  const handlers = new Map<string, PiHandler>();

  try {
    const { default: registerWorktreeIdentity } = await import(`${copy}?test=${Date.now()}`);
    registerWorktreeIdentity({ on: (event: string, handler: PiHandler): void => { handlers.set(event, handler); } });

    // #when
    await handlers.get("before_agent_start")!({ prompt: "Headless prompt" }, {
      hasUI: false,
      cwd: "/worktrees/headless",
      sessionManager: { getSessionId: (): string => "headless-session" },
    });
    await handlers.get("before_agent_start")!({ prompt: "Interactive prompt" }, {
      hasUI: true,
      cwd: "/worktrees/interactive",
      sessionManager: { getSessionId: (): string => "interactive-session" },
    });
  } finally {
    process.env.HOME = previousHome;
  }

  // #then
  expect(await readdir(join(root, "calls"))).toEqual(["0"]);
  expect((await Bun.file(join(root, "calls", "0", "argv")).text()).trim().split("\n")).toEqual([
    "--agent", "pi", "--session", "interactive-session", "--cwd", "/worktrees/interactive",
  ]);
  expect(await Bun.file(join(root, "calls", "0", "stdin")).text()).toBe("Interactive prompt");
});
