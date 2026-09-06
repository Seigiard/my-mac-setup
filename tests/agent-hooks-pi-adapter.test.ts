import { afterEach, describe, expect, test } from "bun:test";
import { cpSync, mkdirSync, mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const EXTENSION_PATH =
  process.env.AGENT_HOOKS_PI_EXTENSION_PATH ??
  join(import.meta.dir, "../home/dot_pi/agent/extensions/agent-hooks.ts");
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

// --- fake pi extension host --------------------------------------------------
//
// The adapter resolves the core once at module scope from $HOME, so the host
// hands each load its own HOME and its own copy of the extension file: bun
// would otherwise return the cached module and the second load would silently
// reuse the first load's core.

type Host = { handlers: Record<string, Function>; events: string[] };

async function loadExtension(coreDir?: string): Promise<Host> {
  const home = temporaryDir("agent-hooks-pi-home-");
  if (coreDir !== undefined) {
    mkdirSync(join(home, ".local", "lib"), { recursive: true });
    symlinkSync(coreDir, join(home, ".local", "lib", "agent-hooks"));
  }

  const copy = join(temporaryDir("agent-hooks-pi-extension-"), `agent-hooks-${loadCount++}.ts`);
  cpSync(EXTENSION_PATH, copy);

  const previousHome = process.env.HOME;
  process.env.HOME = home;
  try {
    const module: any = await import(copy);
    const handlers: Record<string, Function> = {};
    const events: string[] = [];
    const pi = {
      on: (event: string, handler: Function) => {
        events.push(event);
        handlers[event] = handler;
      },
    };
    module.default(pi as never);
    return { handlers, events };
  } finally {
    process.env.HOME = previousHome;
  }
}

/**
 * Awaited on purpose. pi 0.84.4 awaits a promise-returning tool_call handler,
 * so the suite must not be the thing that decides the handler is synchronous —
 * it reads the deny the same way pi would either way.
 */
async function callToolCall(host: Host, raw: any): Promise<any> {
  const handler = host.handlers["tool_call"];
  if (!handler) return undefined;
  return await handler(raw);
}

function piRawFor(fixture: any): any | undefined {
  return normalize.encodeEvent("pi", fixture.tool, fixture.payload, REGISTRY);
}

function policyFixture(policy: string, name: string): any {
  return corpus.policyFixtures(policy).find((candidate: any) => candidate.name === name);
}

// --- scenario 1: the handler contract ---------------------------------------

describe("tool_call deny and allow (R3)", () => {
  test("the known-bad bash fixture is denied with the policy's prefixed reason", async () => {
    // #given the shipped known-bad zsh command in pi's wire shape
    const fixture = policyFixture("zsh-reserved-name-guard", "zsh/flags the status capture idiom");
    const host = await loadExtension(CORE_DIR);

    // #when the handler sees it
    const decision = await callToolCall(host, piRawFor(fixture));

    // #then pi's own deny envelope carries the core's reason verbatim
    expect(decision).toEqual({ block: true, reason: fixture.text });
    expect(fixture.text.startsWith("zsh-reserved-name-guard:")).toBe(true);
  });

  test("the valid control differing only in the variable name is not denied", async () => {
    // #given the same idiom written with a name zsh does not reserve
    const fixture = policyFixture(
      "zsh-reserved-name-guard",
      "zsh/an ordinary name zsh accepts is not blocked",
    );
    const host = await loadExtension(CORE_DIR);

    // #when the handler sees it
    const decision = await callToolCall(host, piRawFor(fixture));

    // #then it returns nothing, which is how pi reads an allow
    expect(decision).toBeUndefined();
  });

  test("a tool pi's profile does not map is left alone", async () => {
    // #given the known-bad command arriving under a spelling outside the profile
    const fixture = policyFixture("zsh-reserved-name-guard", "zsh/blocks status");
    const raw: any = piRawFor(fixture);
    const host = await loadExtension(CORE_DIR);

    // #when the same payload is labelled with an unmapped tool name
    const decision = await callToolCall(host, { toolName: "read", input: raw.input });

    // #then no policy claims it
    expect(decision).toBeUndefined();
  });

  test("a malformed event is allowed rather than thrown out of the handler", async () => {
    // #given an event with no tool name and no input at all
    const host = await loadExtension(CORE_DIR);

    // #when it reaches the handler
    const decision = await callToolCall(host, {});

    // #then the tool call proceeds (R4)
    expect(decision).toBeUndefined();
  });
});

// --- scenario 2: the pi arg dialect -----------------------------------------

describe("pi arg dialect reaches Claude's verdicts (R3, KTD8)", () => {
  test("every shared fixture decides identically through the handler and through Claude", async () => {
    // #given each policy fixture pi has a wire shape for
    const host = await loadExtension(CORE_DIR);
    const shared = corpus.POLICY_FIXTURES.filter((fixture: any) => piRawFor(fixture) !== undefined);
    let denials = 0;
    let clearances = 0;

    for (const fixture of shared) {
      // #when the pi dialect goes through the handler and the claude dialect
      // goes through the same core
      const decision = await callToolCall(host, piRawFor(fixture));
      const claudeRaw = normalize.encodeEvent("claude", fixture.tool, fixture.payload, REGISTRY);
      const claudeDecision = core.dispatch("claude", claudeRaw, { env: {} });

      // #then the deny and its exact reason agree with both Claude and the
      // corpus transcribed from the engines that predate this port
      if (fixture.verdict === "block") {
        denials += 1;
        expect(`${fixture.name}: ${JSON.stringify(decision)}`).toBe(
          `${fixture.name}: ${JSON.stringify({ block: true, reason: fixture.text })}`,
        );
        expect(claudeDecision).toEqual({ verdict: "block", reason: fixture.text });
      } else {
        clearances += 1;
        expect(`${fixture.name}: ${JSON.stringify(decision)}`).toBe(`${fixture.name}: undefined`);
        expect(claudeDecision.verdict).not.toBe("block");
      }
    }

    // Both branches must have been reached, or the loop above proves nothing.
    expect(denials).toBeGreaterThan(0);
    expect(clearances).toBeGreaterThan(0);
  });

});

// --- scenario 3: fail-open by absence ---------------------------------------

describe("fail-open when the core cannot be imported (R4, KTD5)", () => {
  test("no core on disk leaves pi.on uncalled", async () => {
    // #given a home with no deployed core
    // #when the extension loads
    const host = await loadExtension(undefined);

    // #then it registers nothing rather than installing a handler that allows
    expect(host.events).toEqual([]);
    expect(host.handlers["tool_call"]).toBeUndefined();
  });

  test("a core directory whose import throws also registers nothing", async () => {
    // #given a core path that exists but cannot be imported
    const broken = temporaryDir("agent-hooks-broken-core-");
    await Bun.write(join(broken, "index.ts"), "throw new Error('core is broken');\n");

    // #when the extension loads against it
    const host = await loadExtension(broken);

    // #then the same absence, not a handler that silently allows
    expect(host.events).toEqual([]);
  });
});
