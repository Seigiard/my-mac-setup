import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

const PLUGIN_PATH =
  process.env.AGENT_HOOKS_OPENCODE_PLUGIN_PATH ??
  join(import.meta.dir, "../home/private_dot_config/opencode/plugins/agent-hooks.ts");

const CORE_DIR =
  process.env.AGENT_HOOKS_CORE_PATH ?? join(import.meta.dir, "../home/dot_local/lib/agent-hooks");

const core: any = await import(join(CORE_DIR, "index.ts"));

const normalize: any = await import(join(CORE_DIR, "normalize.ts"));

// Dynamic imports can target deployed modules or temporary fixtures with test-specific exports, so this runtime namespace boundary remains `any`.
const selfcheck: any = await import(join(CORE_DIR, "selfcheck.ts"));

import * as corpus from "./fixtures/agent-hooks/fixtures.ts";
import { OPENCODE_V2_CAPTURED_EVENTS } from "./fixtures/agent-hooks/opencode-v2.ts";
import { createReapedPid, createSetupWorktree } from "./fixtures/agent-hooks/setup-worktree.ts";

const REGISTRY = core.CORE_REGISTRY;

const temporaryPaths: string[] = [];

let loadCount = 0;

function temporaryDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  temporaryPaths.push(dir);

  return dir;
}

afterEach(() => {
  for (const path of temporaryPaths.splice(0)) rmSync(path, { recursive: true, force: true });
});

// --- fake opencode plugin host ----------------------------------------------
//
// The adapter resolves the core once at module scope from $HOME, so the host
// hands each load its own HOME and its own copy of the plugin file: bun would
// otherwise return the cached module and the second load would silently reuse
// the first load's core.

type Host = { hooks: Record<string, Function> };

type V2Host = Host & { coreModule?: any };

type V2Session = { location: { directory: string } };

type V2SessionGet = (request: { sessionID: string }) => Promise<V2Session>;

async function loadV2Plugin(
  coreDir?: string,
  pluginPath = PLUGIN_PATH,
  sessionDirectory?: string,
  getSession?: V2SessionGet,
): Promise<V2Host> {
  const home = temporaryDir("agent-hooks-opencode-v2-home-");

  if (coreDir !== undefined) {
    mkdirSync(join(home, ".local", "lib"), { recursive: true });
    symlinkSync(coreDir, join(home, ".local", "lib", "agent-hooks"));
  }

  const module = await importV2Plugin(home, pluginPath);
  const host = await setupV2Plugin(module, home, sessionDirectory, getSession);

  const coreModule =
    coreDir === undefined ? undefined : await import(join(coreDir, "index.ts")).catch(() => undefined);

  return { hooks: host.hooks, coreModule };
}

async function withHome<T>(home: string, action: () => Promise<T>): Promise<T> {
  const previousHome = process.env.HOME;
  process.env.HOME = home;

  try {
    return await action();
  } finally {
    process.env.HOME = previousHome;
  }
}

async function importV2Plugin(home: string, pluginPath = PLUGIN_PATH): Promise<any> {
  const copy = join(temporaryDir("agent-hooks-opencode-v2-plugin-"), `agent-hooks-${loadCount++}.ts`);
  cpSync(pluginPath, copy);

  return withHome(home, () => import(copy));
}

async function setupV2Plugin(
  module: any,
  home: string,
  sessionDirectory = home,
  getSession?: V2SessionGet,
): Promise<Host> {
  const hooks: Record<string, Function> = {};

  await withHome(home, async () => {
    const plugin = module.default;
    expect(plugin?.setup).toBeTypeOf("function");
    await plugin.setup({
      session: {
        get: getSession ?? (async () => ({ location: { directory: sessionDirectory } })),
      },
      tool: {
        hook: async (name: string, handler: Function) => {
          hooks[name] = handler;
        },
      },
    });
  });

  return { hooks };
}

async function callBeforeV2(host: Host, raw: any): Promise<string | undefined> {
  expect(host.hooks["execute.before"]).toBeTypeOf("function");

  try {
    await host.hooks["execute.before"](raw);

    return undefined;
  } catch (error: any) {
    return error?.message;
  }
}

// opencode 2's own wire spellings for the tools the policy corpus exercises,
// written out here rather than produced by the core's encoder. `encodeEvent` is
// the WRITERS half of normalize.ts and the adapter feeds its result straight
// into the READERS half, so an encoder-derived event is the inverse of the
// parser it is about to exercise: a pair that agreed on a wrong field name
// would keep every test below green while real opencode traffic reached no
// policy at all. The tool names `shell` and `fff_grep` are the ones captured
// from OpenCode 2.0.28 in `OPENCODE_V2_CAPTURED_EVENTS`; a deny only fires below
// if the registry still agrees with them.
const OPENCODE_WIRE_TOOLS = {
  bash: "shell",
  "fff-grep": "fff_grep",
} satisfies Record<string, string>;

/** undefined = opencode has no wire shape for that tool, i.e. no route exists. */
function opencodeRawFor(fixture: any): any | undefined {
  const tool = OPENCODE_WIRE_TOOLS[fixture.tool];

  if (tool === undefined) return undefined;

  return { tool, input: { ...fixture.payload } };
}

describe("OpenCode V2 execute.before translation", () => {
  test("a running setup marker blocks a build command but removing it allows the same command", async () => {
    // #given a linked Git worktree whose setup marker names this live test process
    const worktree = createSetupWorktree("agent-hooks-opencode-setup-");
    temporaryPaths.push(worktree.repository);
    await Bun.write(worktree.marker, `running ${process.pid} ${Date.now() + 60_000}\n`);
    const host = await loadV2Plugin(CORE_DIR);

    // #when the native shell event carries the worktree directory before and after marker removal
    const blocked = await callBeforeV2(host, {
      tool: "shell", input: { command: "make test", workdir: worktree.directory },
    });

    rmSync(worktree.marker);

    const allowed = await callBeforeV2(host, {
      tool: "shell", input: { command: "make test", workdir: worktree.directory },
    });

    // #then only the marked invocation reaches OpenCode's rejection transport
    expect([blocked, allowed]).toEqual([
      "worktree-setup-guard: worktree setup is running for 0 s; wait and retry.",
      undefined,
    ]);
  });

  test("a failed setup denies once without a harmless command consuming the marker", async () => {
    // #given a linked worktree whose setup failed
    const worktree = createSetupWorktree("agent-hooks-opencode-failed-setup-");
    temporaryPaths.push(worktree.repository);
    await Bun.write(worktree.marker, `done 7 ${Date.now()}\n`);
    const host = await loadV2Plugin(CORE_DIR);
    const reason = "worktree-setup-guard: setup failed with 7; run `mise exec -- make setup`. If that also fails, report and stop.";

    // #when the host receives a harmless event, then two build events from that worktree
    const harmless = await callBeforeV2(host, { tool: "shell", input: { command: "git status", workdir: worktree.directory } });
    const first = await callBeforeV2(host, { tool: "shell", input: { command: "npm test", workdir: worktree.directory } });
    const second = await callBeforeV2(host, { tool: "shell", input: { command: "npm test", workdir: worktree.directory } });

    // #then the failure reaches the user exactly once and the harmless event does not acknowledge it
    expect([harmless, first, second]).toEqual([undefined, reason, undefined]);
  });

  test("an unwritable deny-once record fails open through execute.before", async () => {
    // #given a failed setup whose marker directory cannot accept its denial record
    const worktree = createSetupWorktree("agent-hooks-opencode-denial-record-");
    temporaryPaths.push(worktree.repository);
    await Bun.write(worktree.marker, "done 7 1700000000000\n");
    const markerDirectory = dirname(worktree.marker);
    chmodSync(markerDirectory, 0o500);
    const host = await loadV2Plugin(CORE_DIR);
    const event = { tool: "shell", input: { command: "npm test", workdir: worktree.directory } };

    try {
      // #when consecutive build calls reach OpenCode's rejection transport
      const results = [await callBeforeV2(host, event), await callBeforeV2(host, event)];

      // #then neither call rejects when deny-once memory cannot be recorded
      expect(results).toEqual([undefined, undefined]);
    } finally {
      chmodSync(markerDirectory, 0o700);
    }
  });

  test("a missing or relative workdir uses OpenCode's setup location", async () => {
    // #given the event's session resolves to a marked worktree while the plugin process is elsewhere
    const worktree = createSetupWorktree("agent-hooks-opencode-location-");
    temporaryPaths.push(worktree.repository);
    await Bun.write(worktree.marker, `running ${process.pid} ${Date.now() + 60_000}\n`);
    const pluginCwd = temporaryDir("agent-hooks-opencode-no-marker-");
    const sessionID = "ses-agent-hooks-worktree";

    const host = await loadV2Plugin(CORE_DIR, PLUGIN_PATH, worktree.directory, async (request) => {
      if (request.sessionID !== sessionID) throw new Error("unexpected session");

      return { location: { directory: worktree.directory } };
    });

    const lookupFails = await loadV2Plugin(CORE_DIR, PLUGIN_PATH, worktree.directory, async () => {
      throw new Error("session lookup failed");
    });

    const reason = "worktree-setup-guard: worktree setup is running for 0 s; wait and retry.";
    const previousCwd = process.cwd();

    process.chdir(pluginCwd);

    try {
      // #when a shell call omits workdir, uses a relative workdir, or cannot resolve its session
      const missing = await callBeforeV2(host, { sessionID, tool: "shell", input: { command: "make test" } });

      const relative = await callBeforeV2(host, {
        sessionID,
        tool: "shell",
        input: { command: "make test", workdir: "." },
      });

      const fallback = await callBeforeV2(lookupFails, { sessionID, tool: "shell", input: { command: "make test" } });

      // #then the session directory gates missing and relative workdirs, while a failed lookup falls back open
      expect([missing, relative, fallback]).toEqual([reason, reason, undefined]);
    } finally {
      process.chdir(previousCwd);
    }
  });

  test("a malformed marker fails open through the registered V2 transport", async () => {
    // #given a real linked worktree with marker content outside the producer contract
    const worktree = createSetupWorktree("agent-hooks-opencode-malformed-setup-");
    temporaryPaths.push(worktree.repository);
    await Bun.write(worktree.marker, "still starting maybe\n");
    const host = await loadV2Plugin(CORE_DIR);

    // #when a build command reaches execute.before
    const result = await callBeforeV2(host, { tool: "shell", input: { command: "bun test", workdir: worktree.directory } });

    // #then a bad marker does not become an adapter rejection
    expect(result).toBeUndefined();
  });

  test("a dead running marker blocks as interrupted through the native workdir", async () => {
    // #given a linked worktree whose marker names a child that has exited
    const worktree = createSetupWorktree("agent-hooks-opencode-interrupted-setup-");
    temporaryPaths.push(worktree.repository);
    const pid = await createReapedPid();
    await Bun.write(worktree.marker, `running ${pid} ${Date.now()}\n`);
    const host = await loadV2Plugin(CORE_DIR);

    // #when OpenCode carries the working directory in the shell input
    const result = await callBeforeV2(host, {
      tool: "shell", input: { command: "bun test", workdir: worktree.directory },
    });

    // #then the interrupted setup gives the documented recovery denial
    expect(result).toBe(
      "worktree-setup-guard: worktree setup was interrupted; run `mise exec -- make setup`. If that also fails, report and stop.",
    );
  });

  test("a new failed marker denies again after the earlier marker was acknowledged", async () => {
    // #given a worktree with one failure marker and a later distinct failure marker
    const worktree = createSetupWorktree("agent-hooks-opencode-new-failure-setup-");
    temporaryPaths.push(worktree.repository);
    await Bun.write(worktree.marker, "done 7 1700000000000\n");
    const host = await loadV2Plugin(CORE_DIR);
    const firstReason = "worktree-setup-guard: setup failed with 7; run `mise exec -- make setup`. If that also fails, report and stop.";
    const secondReason = "worktree-setup-guard: setup failed with 8; run `mise exec -- make setup`. If that also fails, report and stop.";
    const event = { tool: "shell", input: { command: "npm test", workdir: worktree.directory } };

    // #when one call acknowledges the first line and the marker writer records a new failure
    const first = await callBeforeV2(host, event);
    const acknowledged = await callBeforeV2(host, event);
    await Bun.write(worktree.marker, "done 8 1700000000001\n");
    const newFailure = await callBeforeV2(host, event);

    // #then each distinct failure line reaches OpenCode once
    expect([first, acknowledged, newFailure]).toEqual([firstReason, undefined, secondReason]);
  });

  test("the V2 host control distinguishes a registered allow from a rejection", async () => {
    // #given a control plugin with one allow input and one rejection input
    const controlPlugin = join(temporaryDir("agent-hooks-v2-control-plugin-"), "control.ts");
    await Bun.write(
      controlPlugin,
      "export default { async setup(ctx) { await ctx.tool.hook('execute.before', async (event) => {" +
        " if (event.tool === 'reject') throw new Error('control rejection'); }); } };\n",
    );
    const host = await loadV2Plugin(undefined, controlPlugin);

    // #when both inputs reach the fake host callback
    const allowed = await callBeforeV2(host, { tool: "allow", input: {} });
    const rejected = await callBeforeV2(host, { tool: "reject", input: {} });

    // #then the helper reports the callback's two distinct outcomes
    expect(allowed).toBeUndefined();
    expect(rejected).toBe("control rejection");
  });

  test("missing or broken core imports register no V2 execute handler", async () => {
    // #given one absent core and one core whose import throws
    const broken = temporaryDir("agent-hooks-v2-broken-core-");
    await Bun.write(join(broken, "index.ts"), "throw new Error('core is broken');\n");

    // #when each plugin setup runs
    const missingHost = await loadV2Plugin(undefined);
    const brokenHost = await loadV2Plugin(broken);

    // #then both fail open by leaving the execution hook absent
    expect(Object.keys(missingHost.hooks)).toEqual([]);
    expect(Object.keys(brokenHost.hooks)).toEqual([]);
  });

  test("a denied shell command and its renamed control keep the shipped verdicts", async () => {
    // #given the pre-port deny and allow commands in the V2 shell event shape
    const denied = corpus
      .policyFixtures("zsh-reserved-name-guard")
      .find((candidate) => candidate.name === "zsh/flags the status capture idiom");

    const allowed = corpus
      .policyFixtures("zsh-reserved-name-guard")
      .find((candidate) => candidate.name === "zsh/an ordinary name zsh accepts is not blocked");

    const host = await loadV2Plugin(CORE_DIR);

    // #when both commands reach the V2 callback
    const deniedMessage = await callBeforeV2(host, { tool: "shell", input: denied.payload });
    const allowedMessage = await callBeforeV2(host, { tool: "shell", input: allowed.payload });

    // #then only the reserved name is refused with the existing reason
    expect(deniedMessage).toBe(denied.text);
    expect(allowedMessage).toBeUndefined();
  });

  test("a nested FFF deny and its single-identifier control keep the shipped verdicts", async () => {
    // #given the pre-port FFF deny and allow queries under the captured nested tool name
    const denied = corpus
      .policyFixtures("fff-grep-guard")
      .find((candidate) => candidate.name === "fff/multi-token bare query is denied");

    const allowed = corpus
      .policyFixtures("fff-grep-guard")
      .find((candidate) => candidate.name === "fff/single identifier passes");

    const host = await loadV2Plugin(CORE_DIR);

    // #when Code Mode's nested events reach the V2 callback
    const deniedMessage = await callBeforeV2(host, { tool: "fff_grep", input: denied.payload });
    const allowedMessage = await callBeforeV2(host, { tool: "fff_grep", input: allowed.payload });

    // #then only the multi-token query is refused with the existing reason
    expect(deniedMessage).toBe(denied.text);
    expect(allowedMessage).toBeUndefined();
  });

  test("native write and edit path and content survive transport translation", async () => {
    // #given a core that records the adapter event without deciding its value
    const capturing = temporaryDir("agent-hooks-v2-capturing-core-");
    await Bun.write(
      join(capturing, "index.ts"),
      "export const observed = [];\n" +
        "export function dispatch(client, raw) { observed.push({ client, raw }); return { verdict: 'allow' }; }\n",
    );
    const host = await loadV2Plugin(capturing);

    // #when the captured native mutation events reach the adapter
    await callBeforeV2(host, OPENCODE_V2_CAPTURED_EVENTS.write);
    await callBeforeV2(host, OPENCODE_V2_CAPTURED_EVENTS.edit);

    // #then the core receives the exact tool, path, and content-bearing V2 inputs
    expect(host.coreModule.observed).toEqual([
      { client: "opencode", raw: OPENCODE_V2_CAPTURED_EVENTS.write },
      { client: "opencode", raw: OPENCODE_V2_CAPTURED_EVENTS.edit },
    ]);
  });

  test("a V2 dispatch exception fails open without swallowing an explicit denial", async () => {
    // #given one throwing core and one real core denial
    const throwing = temporaryDir("agent-hooks-v2-throwing-core-");
    await Bun.write(
      join(throwing, "index.ts"),
      "export function dispatch() { throw new Error('policy exploded'); }\n",
    );
    const throwingHost = await loadV2Plugin(throwing);
    const denyingHost = await loadV2Plugin(CORE_DIR);

    const denied = corpus
      .policyFixtures("zsh-reserved-name-guard")
      .find((candidate) => candidate.name === "zsh/blocks status");

    const raw = { tool: "shell", input: denied.payload };

    // #when the same valid V2 callback path sees integration failure and policy denial
    const failureMessage = await callBeforeV2(throwingHost, raw);
    const denialMessage = await callBeforeV2(denyingHost, raw);

    // #then only the explicit policy verdict rejects the tool call
    expect(failureMessage).toBeUndefined();
    expect(denialMessage).toBe(denied.text);
  });

  test("a malformed V2 event fails open", async () => {
    // #given a loaded V2 adapter and an event outside the callback contract
    const host = await loadV2Plugin(CORE_DIR);

    // #when normalization receives no event object
    const message = await callBeforeV2(host, null);

    // #then the tool path is not converted into an integration denial
    expect(message).toBeUndefined();
  });
});

describe("OpenCode V2 resident core identity (R1, KTD5)", () => {
  const denied = corpus
    .policyFixtures("zsh-reserved-name-guard")
    .find((candidate) => candidate.name === "zsh/blocks status");

  type ResidentIdentity = {
    status: "current" | "stale";
    live?: Array<{ hash: string }>;
    stale?: Array<{ hash: string }>;
  };

  function inspectResident(home: string, deployedHash: string): ResidentIdentity {
    const stateDir = join(home, ".local", "state", "agent-hooks");
    const startedAt = selfcheck.processStartTime(process.pid);

    // SAFETY: the request names exactly one client, so the report's first
    // entry is that client's resident identity.
    return selfcheck.inspectIdentity({
      stateDir,
      deployedHash,
      clients: ["opencode"],
      markerlessClients: [],
      isAlive: (pid: number) => pid === process.pid,
      getProcessStart: (pid: number) => (pid === process.pid ? startedAt : null),
    }).clients[0] as ResidentIdentity;
  }

  async function runtimeWithCoreA() {
    const coreDir = temporaryDir("agent-hooks-opencode-v2-core-");
    const home = temporaryDir("agent-hooks-opencode-v2-resident-");
    cpSync(CORE_DIR, coreDir, { recursive: true });
    const copiedDependencies = join(coreDir, "node_modules");

    if (!existsSync(copiedDependencies)) {
      symlinkSync(join(import.meta.dir, "../node_modules"), copiedDependencies);
    }

    mkdirSync(join(home, ".local", "lib"), { recursive: true });
    symlinkSync(coreDir, join(home, ".local", "lib", "agent-hooks"));

    return { coreDir, home, module: await importV2Plugin(home) };
  }

  async function replaceCoreWithB(coreDir: string): Promise<string> {
    const guard = join(coreDir, "policies", "zsh-reserved-name-guard.ts");
    const source = await Bun.file(guard).text();
    await Bun.write(guard, source.replace("if (found.length === 0) return ALLOW;", "return ALLOW;"));

    const result = Bun.spawnSync([process.execPath, "-e", `
      const { dispatch } = await import(${JSON.stringify(join(coreDir, "index.ts"))});
      console.log(dispatch("opencode", { tool: "shell", input: { command: ${JSON.stringify(denied.payload.command)} } }).verdict);
    `]);

    expect(result.exitCode).toBe(0);
    expect(result.stdout.toString().trim()).toBe("allow");

    return selfcheck.coreHash(coreDir);
  }

  test("repeated setup keeps the resident A marker stale after deployed core B replaces it", async () => {
    // #given a V2 plugin that has loaded and registered core A
    const runtime = await runtimeWithCoreA();
    const hashA = selfcheck.coreHash(runtime.coreDir);
    await setupV2Plugin(runtime.module, runtime.home);

    // #when deployed core B changes on disk and setup repeats in the same process
    const hashB = await replaceCoreWithB(runtime.coreDir);
    const hooks = await setupV2Plugin(runtime.module, runtime.home);
    const enforcement = await callBeforeV2(hooks, { tool: "shell", input: denied.payload });
    const identity = inspectResident(runtime.home, hashB);

    // #then cached A still enforces and selfcheck reports its distinct identity as stale
    expect(hashB).not.toBe(hashA);
    expect(enforcement).toBe(denied.text);
    expect(identity).toMatchObject({ status: "stale", stale: [{ hash: hashA }] });
  });

  test("a separately evaluated adapter generation keeps the resident A marker stale after core B deploys", async () => {
    // #given a V2 plugin whose first generation has loaded core A
    const runtime = await runtimeWithCoreA();
    const hashA = selfcheck.coreHash(runtime.coreDir);
    await setupV2Plugin(runtime.module, runtime.home);

    // #when core B deploys and a unique plugin import evaluates the adapter again
    const hashB = await replaceCoreWithB(runtime.coreDir);
    const reloadedModule = await importV2Plugin(runtime.home);
    const reloadIdentity = inspectResident(runtime.home, hashB);
    const hooks = await setupV2Plugin(reloadedModule, runtime.home);
    const enforcement = await callBeforeV2(hooks, { tool: "shell", input: denied.payload });

    // #then re-evaluation records cached A before setup, and setup still enforces A
    expect(enforcement).toBe(denied.text);
    expect(reloadIdentity).toMatchObject({ status: "stale", stale: [{ hash: hashA }] });
  });

  test("an unchanged deployed core reports the resident identity as current across setup and re-evaluation", async () => {
    // #given a V2 plugin and its unchanged deployed core
    const runtime = await runtimeWithCoreA();
    const hashA = selfcheck.coreHash(runtime.coreDir);
    await setupV2Plugin(runtime.module, runtime.home);

    // #when setup repeats and a unique plugin import evaluates again
    const reloadedModule = await importV2Plugin(runtime.home);
    await setupV2Plugin(reloadedModule, runtime.home);
    const identity = inspectResident(runtime.home, hashA);

    // #then the marker correctly remains current
    expect(identity).toMatchObject({ status: "current", live: [{ hash: hashA }] });
  });
});

// --- dialect parity with Claude ---------------------------------------------

describe("opencode V2 input dialect reaches Claude's verdicts (R3, KTD8)", () => {
  test("every shared fixture decides identically through the plugin and through Claude", async () => {
    // #given each policy fixture opencode has a wire shape for
    const host = await loadV2Plugin(CORE_DIR);

    const shared = corpus.POLICY_FIXTURES.filter(
      (fixture: any) => opencodeRawFor(fixture) !== undefined,
    );

    let denials = 0;
    let clearances = 0;
    // Cardinality before the loop: `shared` is selected by this file's own wire
    // table, so a route that disappears from it shrinks the loop instead of
    // failing it. 19 is the corpus's own count of bash and fff-grep fixtures,
    // 9 of which deny -- an independent side from the wire table doing the
    // selecting.
    expect([
      shared.length,
      shared.filter((fixture: any) => fixture.tool === "bash").length,
      shared.filter((fixture: any) => fixture.tool === "fff-grep").length,
    ]).toEqual([19, 14, 5]);

    for (const fixture of shared) {
      // #when the opencode dialect goes through the handler and the claude
      // dialect goes through the same core
      const thrown = await callBeforeV2(host, opencodeRawFor(fixture));
      const claudeRaw = normalize.encodeEvent("claude", fixture.tool, fixture.payload, REGISTRY);
      const claudeDecision = core.dispatch("claude", claudeRaw, { env: {} });

      // #then the deny and its exact reason agree with both Claude and the
      // corpus transcribed from the engines that predate this port
      if (fixture.verdict === "block") {
        denials += 1;
        expect(`${fixture.name}: ${thrown}`).toBe(`${fixture.name}: ${fixture.text}`);
        expect(claudeDecision).toEqual({ verdict: "block", reason: fixture.text });
      } else {
        clearances += 1;
        expect(`${fixture.name}: ${thrown}`).toBe(`${fixture.name}: undefined`);
        // `shared` holds only the bash and fff-grep fixtures, so allow is the
        // one non-block outcome here: a stray context decision is a defect,
        // not something this branch may accept.
        expect(claudeDecision).toEqual({ verdict: "allow" });
      }
    }

    // Both branches reached, and each for its whole share of the corpus.
    expect([denials, clearances]).toEqual([9, 10]);
  });

  test("a tool opencode's profile does not map is left alone, its mapped spelling is denied", async () => {
    // #given a known-bad command and the host's two spellings of the tool
    const fixture = corpus
      .policyFixtures("zsh-reserved-name-guard")
      .find((candidate: any) => candidate.name === "zsh/blocks status");

    const host = await loadV2Plugin(CORE_DIR);

    // #when it arrives under an unmapped and under the mapped spelling
    const unmapped = await callBeforeV2(host, { tool: "webfetch", input: fixture.payload });
    const mapped = await callBeforeV2(host, opencodeRawFor(fixture));

    // #then only the mapped spelling reaches a policy
    expect([unmapped, mapped]).toEqual([undefined, fixture.text]);
  });
});
