import { afterEach, describe, expect, test } from "bun:test";
import { cpSync, mkdirSync, mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const PLUGIN_PATH =
  process.env.AGENT_HOOKS_OPENCODE_PLUGIN_PATH ??
  join(import.meta.dir, "../home/private_dot_config/opencode/plugins/agent-hooks.ts");
const CORE_DIR =
  process.env.AGENT_HOOKS_CORE_PATH ?? join(import.meta.dir, "../home/dot_local/lib/agent-hooks");

const core: any = await import(join(CORE_DIR, "index.ts"));
const normalize: any = await import(join(CORE_DIR, "normalize.ts"));
const corpus: any = await import(join(CORE_DIR, "fixtures.ts"));

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

async function loadPlugin(coreDir?: string): Promise<Host> {
  const home = temporaryDir("agent-hooks-opencode-home-");
  if (coreDir !== undefined) {
    mkdirSync(join(home, ".local", "lib"), { recursive: true });
    symlinkSync(coreDir, join(home, ".local", "lib", "agent-hooks"));
  }

  const copy = join(temporaryDir("agent-hooks-opencode-plugin-"), `agent-hooks-${loadCount++}.ts`);
  cpSync(PLUGIN_PATH, copy);

  const previousHome = process.env.HOME;
  process.env.HOME = home;
  try {
    const module: any = await import(copy);
    const hooks = (await module.AgentHooksPlugin({ directory: home, worktree: home })) ?? {};
    return { hooks };
  } finally {
    process.env.HOME = previousHome;
  }
}

/**
 * opencode passes the tool name on `input` and the mutable arguments on
 * `output`; splitting them here keeps the suite honest about which half the
 * adapter has to read from where.
 */
async function callBefore(host: Host, raw: any): Promise<string | undefined> {
  try {
    await host.hooks["tool.execute.before"]({ tool: raw.tool }, { args: raw.args });
    return undefined;
  } catch (error: any) {
    return error?.message;
  }
}

// opencode's own wire spellings for the tools the policy corpus exercises,
// written out here rather than produced by the core's encoder. `encodeEvent` is
// the WRITERS half of normalize.ts and the adapter feeds its result straight
// into the READERS half, so an encoder-derived event is the inverse of the
// parser it is about to exercise: a pair that agreed on a wrong field name
// (`args.cmd` for `args.command`) would keep every test below green while real
// opencode traffic reached no policy at all. Source is the same as the corpus's
// hand-written `raw.opencode` entries — the shipped adapter. `fff_grep` is the
// flattened MCP spelling observed against the deployed fff server (U4); a deny
// only fires below if the registry still agrees with it.
const OPENCODE_WIRE: Record<string, { tool: string; argNames: Record<string, string> }> = {
  bash: { tool: "bash", argNames: { command: "command" } },
  "fff-grep": { tool: "fff_grep", argNames: { query: "query" } },
};

/** undefined = opencode has no wire shape for that tool, i.e. no route exists. */
function opencodeRawFor(fixture: any): any | undefined {
  const wire = OPENCODE_WIRE[fixture.tool];
  if (wire === undefined) return undefined;
  const args: Record<string, unknown> = {};
  for (const [field, value] of Object.entries(fixture.payload)) args[wire.argNames[field]] = value;
  return { tool: wire.tool, args };
}

// --- scenario 1: the handler contract ---------------------------------------

describe("tool.execute.before deny and allow (R3)", () => {
  test("a bash command assigning a reserved zsh name is denied, its renamed control is not", async () => {
    // #given two commands that differ only in the variable name
    const denied = corpus
      .policyFixtures("zsh-reserved-name-guard")
      .find((candidate: any) => candidate.name === "zsh/flags the status capture idiom");
    const allowed = corpus
      .policyFixtures("zsh-reserved-name-guard")
      .find((candidate: any) => candidate.name === "zsh/an ordinary name zsh accepts is not blocked");
    const host = await loadPlugin(CORE_DIR);

    // #when both reach the handler
    const deniedMessage = await callBefore(host, opencodeRawFor(denied));
    const allowedMessage = await callBefore(host, opencodeRawFor(allowed));

    // #then only the reserved name is refused
    expect(deniedMessage).toBe(denied.text);
    expect(allowedMessage).toBeUndefined();
  });

  test("the arguments are read from the second handler argument, not the first", async () => {
    // #given the known-bad command supplied only where opencode really puts it
    const fixture = corpus
      .policyFixtures("zsh-reserved-name-guard")
      .find((candidate: any) => candidate.name === "zsh/blocks status");
    const raw: any = opencodeRawFor(fixture);
    const host = await loadPlugin(CORE_DIR);

    // #when input carries the tool name and output carries the args
    let thrown: string | undefined;
    try {
      await host.hooks["tool.execute.before"]({ tool: raw.tool, args: {} }, { args: raw.args });
    } catch (error: any) {
      thrown = error?.message;
    }

    // #then the deny still fires, so the adapter did not read args off input
    expect(thrown).toBe(fixture.text);
  });

  test("a tool opencode's profile does not map is left alone", async () => {
    // #given a tool name outside the profile carrying a known-bad payload
    const fixture = corpus
      .policyFixtures("zsh-reserved-name-guard")
      .find((candidate: any) => candidate.name === "zsh/blocks status");
    const raw: any = opencodeRawFor(fixture);
    const host = await loadPlugin(CORE_DIR);

    // #when it arrives under an unmapped spelling
    const thrown = await callBefore(host, { tool: "webfetch", args: raw.args });

    // #then no policy claims it
    expect(thrown).toBeUndefined();
  });
});

// --- scenario 2: fail-open by absence ---------------------------------------

describe("fail-open when the core cannot be imported (R4, KTD5)", () => {
  test("no core on disk leaves the plugin with no tool.execute.before handler", async () => {
    // #given a home with no deployed core
    // #when the plugin loads
    const host = await loadPlugin(undefined);

    // #then it registers nothing rather than installing a handler that allows
    expect(Object.keys(host.hooks)).toEqual([]);
    expect(host.hooks["tool.execute.before"]).toBeUndefined();
  });

  test("a core directory whose import throws also registers nothing", async () => {
    // #given a core path that exists but cannot be imported
    const broken = temporaryDir("agent-hooks-broken-core-");
    await Bun.write(join(broken, "index.ts"), "throw new Error('core is broken');\n");

    // #when the plugin loads against it
    const host = await loadPlugin(broken);

    // #then the same absence, not a handler that silently allows
    expect(Object.keys(host.hooks)).toEqual([]);
  });

  test("a dispatch that throws at call time still lets the tool call proceed", async () => {
    // #given a core that imports cleanly but whose dispatch throws
    const throwing = temporaryDir("agent-hooks-throwing-core-");
    await Bun.write(
      join(throwing, "index.ts"),
      "export function dispatch() { throw new Error('policy exploded'); }\n",
    );
    const host = await loadPlugin(throwing);

    // #when a known-bad command reaches the registered handler
    const fixture = corpus
      .policyFixtures("zsh-reserved-name-guard")
      .find((candidate: any) => candidate.name === "zsh/blocks status");
    const thrown = await callBefore(host, opencodeRawFor(fixture));

    // #then the handler exists and the call is allowed through: R4 requires a
    // dispatch exception to fail open, not to surface as a deny opencode would
    // present to the model as a refusal.
    expect(Object.keys(host.hooks)).toEqual(["tool.execute.before"]);
    expect(thrown).toBeUndefined();
  });
});

// --- scenario 3: dialect parity with Claude ---------------------------------

describe("opencode arg dialect reaches Claude's verdicts (R3, KTD8)", () => {
  test("every shared fixture decides identically through the plugin and through Claude", async () => {
    // #given each policy fixture opencode has a wire shape for
    const host = await loadPlugin(CORE_DIR);
    const shared = corpus.POLICY_FIXTURES.filter(
      (fixture: any) => opencodeRawFor(fixture) !== undefined,
    );
    let denials = 0;
    let clearances = 0;

    for (const fixture of shared) {
      // #when the opencode dialect goes through the handler and the claude
      // dialect goes through the same core
      const thrown = await callBefore(host, opencodeRawFor(fixture));
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

    // Both branches must have been reached, or the loop above proves nothing.
    expect(denials).toBeGreaterThan(0);
    expect(clearances).toBeGreaterThan(0);
  });

  test("the fff route opencode exposes decides like Claude's", async () => {
    // #given the bare multi-token query fixture
    const fixture = corpus
      .policyFixtures("fff-grep-guard")
      .find((candidate: any) => candidate.name === "fff/multi-token bare query is denied");
    const control = corpus
      .policyFixtures("fff-grep-guard")
      .find((candidate: any) => candidate.name === "fff/single identifier passes");
    const host = await loadPlugin(CORE_DIR);

    // #when both go through opencode's verified fff tool spelling
    const thrown = await callBefore(host, opencodeRawFor(fixture));
    const allowed = await callBefore(host, opencodeRawFor(control));

    // #then only the multi-token query is refused. The deny is what proves the
    // registry still spells this route `fff_grep`: an unmapped tool name falls
    // open and `thrown` would be undefined.
    expect(thrown).toBe(fixture.text);
    expect(allowed).toBeUndefined();
  });
});
