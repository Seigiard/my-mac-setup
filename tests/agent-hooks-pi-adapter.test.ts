import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, cpSync, mkdirSync, mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";

const EXTENSION_PATH =
  process.env.AGENT_HOOKS_PI_EXTENSION_PATH ??
  join(import.meta.dir, "../home/dot_pi/private_agent/extensions/agent-hooks.ts");

const CORE_DIR =
  process.env.AGENT_HOOKS_CORE_PATH ?? join(import.meta.dir, "../home/dot_local/lib/agent-hooks");

const core: any = await import(join(CORE_DIR, "index.ts"));

const normalize: any = await import(join(CORE_DIR, "normalize.ts"));

import * as corpus from "./fixtures/agent-hooks/fixtures.ts";
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

    module.default(pi);

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
async function callToolCall(host: Host, raw: any, context: { cwd?: string } = {}): Promise<any> {
  const handler = host.handlers["tool_call"];
  // An absent handler is exactly the `undefined` the allow tests below expect,
  // so a broken $HOME symlink, a moved index.ts or a renamed dispatch export
  // would read as "the tool call proceeded". Refuse to answer for the
  // extension when the extension never registered.
  expect(handler).toBeTypeOf("function");

  return await handler(raw, context);
}

// pi's own wire spellings for the tools the policy corpus exercises, written out
// here rather than produced by the core's encoder. `encodeEvent` is the WRITERS
// half of normalize.ts and the handler feeds its result straight into the
// READERS half, so an encoder-derived event is the inverse of the parser it is
// about to exercise: a pair that agreed on a wrong field name would keep every
// test below green while real pi traffic reached no policy. Source is the same
// as the corpus's hand-written `raw.pi` entries — the shipped adapter, with
// `ffgrep`/`pattern` as pi-fff spells them in its default tools-and-ui mode.
const PI_WIRE = {
  bash: { toolName: "bash", fields: { command: "command" } },
  "fff-grep": { toolName: "ffgrep", fields: { query: "pattern" } },
};

/** undefined = pi has no wire shape for that tool, i.e. no route exists. */
function piRawFor(fixture: any): any | undefined {
  const wire = PI_WIRE[fixture.tool];

  if (wire === undefined) return undefined;
  const input: Record<string, string> = {};

  for (const [field, value] of Object.entries(fixture.payload)) input[wire.fields[field]] = value;

  return { toolName: wire.toolName, input };
}

function policyFixture(policy: string, name: string): any {
  return corpus.policyFixtures(policy).find((candidate: any) => candidate.name === name);
}

// --- scenario 1: the handler contract ---------------------------------------

describe("tool_call deny and allow (R3)", () => {
  test("a running setup marker blocks a build command but removing it allows the same command", async () => {
    // #given a linked Git worktree whose setup marker names this live test process
    const worktree = createSetupWorktree("agent-hooks-pi-setup-");
    temporaryPaths.push(worktree.repository);
    await Bun.write(worktree.marker, `running ${process.pid} ${Date.now() + 60_000}\n`);
    const host = await loadExtension(CORE_DIR);

    // #when pi sends the build call before and after the marker is removed
    const blocked = await callToolCall(host, {
      toolName: "bash", input: { command: "make test" },
    }, { cwd: worktree.directory });

    rmSync(worktree.marker);

    const allowed = await callToolCall(host, {
      toolName: "bash", input: { command: "make test" },
    }, { cwd: worktree.directory });

    // #then only the marked call returns pi's block envelope
    expect([blocked, allowed]).toEqual([
      { block: true, reason: "worktree-setup-guard: worktree setup is running for 0 s; wait and retry." },
      undefined,
    ]);
  });

  test("a failed setup denies once without a harmless command consuming the marker", async () => {
    // #given a linked worktree whose setup failed
    const worktree = createSetupWorktree("agent-hooks-pi-failed-setup-");
    temporaryPaths.push(worktree.repository);
    await Bun.write(worktree.marker, `done 7 ${Date.now()}\n`);
    const host = await loadExtension(CORE_DIR);
    const reason = "worktree-setup-guard: setup failed with 7; run `mise exec -- make setup`. If that also fails, report and stop.";

    // #when pi receives a harmless event, then two build events from that worktree
    const harmless = await callToolCall(host, { toolName: "bash", input: { command: "git status" } }, { cwd: worktree.directory });
    const first = await callToolCall(host, { toolName: "bash", input: { command: "npm test" } }, { cwd: worktree.directory });
    const second = await callToolCall(host, { toolName: "bash", input: { command: "npm test" } }, { cwd: worktree.directory });

    // #then the failure blocks once and only a gated command acknowledges it
    expect([harmless, first, second]).toEqual([undefined, { block: true, reason }, undefined]);
  });

  test("an unwritable deny-once record fails open through tool_call", async () => {
    // #given a failed setup whose marker directory cannot accept its denial record
    const worktree = createSetupWorktree("agent-hooks-pi-denial-record-");
    temporaryPaths.push(worktree.repository);
    await Bun.write(worktree.marker, "done 7 1700000000000\n");
    const markerDirectory = dirname(worktree.marker);
    chmodSync(markerDirectory, 0o500);
    const host = await loadExtension(CORE_DIR);
    const event = { toolName: "bash", input: { command: "npm test" } };
    const context = { cwd: worktree.directory };

    try {
      // #when consecutive build calls reach Pi's tool-call transport
      const results = [await callToolCall(host, event, context), await callToolCall(host, event, context)];

      // #then neither call blocks when deny-once memory cannot be recorded
      expect(results).toEqual([undefined, undefined]);
    } finally {
      chmodSync(markerDirectory, 0o700);
    }
  });

  test("exec_command and bash resolve input workdir from the pi call context", async () => {
    // #given a context checkout without a marker and a relative marked target checkout
    const context = createSetupWorktree("agent-hooks-pi-workdir-context-");
    const target = createSetupWorktree("agent-hooks-pi-workdir-target-");
    temporaryPaths.push(context.repository, target.repository);
    await Bun.write(target.marker, `running ${process.pid} ${Date.now() + 60_000}\n`);
    const host = await loadExtension(CORE_DIR);
    const workdir = relative(context.directory, target.directory);
    const reason = "worktree-setup-guard: worktree setup is running for 0 s; wait and retry.";

    // #when Pi targets the marked checkout through each shell-capable wire shape
    const exec = await callToolCall(host, {
      toolName: "exec_command", input: { cmd: "make test", workdir },
    }, { cwd: context.directory });

    const bash = await callToolCall(host, {
      toolName: "bash", input: { command: "make test", workdir },
    }, { cwd: context.directory });

    // #then both calls use the command's resolved directory, not the session directory
    expect([exec, bash]).toEqual([{ block: true, reason }, { block: true, reason }]);
  });

  test("a malformed marker fails open through the pi tool_call transport", async () => {
    // #given a real linked worktree with marker content outside the producer contract
    const worktree = createSetupWorktree("agent-hooks-pi-malformed-setup-");
    temporaryPaths.push(worktree.repository);
    await Bun.write(worktree.marker, "still starting maybe\n");
    const host = await loadExtension(CORE_DIR);

    // #when a build command reaches tool_call
    const result = await callToolCall(host, {
      toolName: "bash", input: { command: "bun test" },
    }, { cwd: worktree.directory });

    // #then a bad marker does not become a block
    expect(result).toBeUndefined();
  });

  test("a dead running marker blocks as interrupted through the tool-call context", async () => {
    // #given a linked worktree whose marker names a child that has exited
    const worktree = createSetupWorktree("agent-hooks-pi-interrupted-setup-");
    temporaryPaths.push(worktree.repository);
    const pid = await createReapedPid();
    await Bun.write(worktree.marker, `running ${pid} ${Date.now()}\n`);
    const host = await loadExtension(CORE_DIR);

    // #when pi supplies the worktree directory as the tool-call context
    const result = await callToolCall(host, { toolName: "bash", input: { command: "bun test" } }, { cwd: worktree.directory });

    // #then the interrupted setup gives the documented recovery denial
    expect(result).toEqual({
      block: true,
      reason: "worktree-setup-guard: worktree setup was interrupted; run `mise exec -- make setup`. If that also fails, report and stop.",
    });
  });

  test("a new failed marker denies again after the earlier marker was acknowledged", async () => {
    // #given a worktree with one failure marker and a later distinct failure marker
    const worktree = createSetupWorktree("agent-hooks-pi-new-failure-setup-");
    temporaryPaths.push(worktree.repository);
    await Bun.write(worktree.marker, "done 7 1700000000000\n");
    const host = await loadExtension(CORE_DIR);
    const firstReason = "worktree-setup-guard: setup failed with 7; run `mise exec -- make setup`. If that also fails, report and stop.";
    const secondReason = "worktree-setup-guard: setup failed with 8; run `mise exec -- make setup`. If that also fails, report and stop.";
    const event = { toolName: "bash", input: { command: "npm test" } };
    const context = { cwd: worktree.directory };

    // #when one call acknowledges the first line and the marker writer records a new failure
    const first = await callToolCall(host, event, context);
    const acknowledged = await callToolCall(host, event, context);
    await Bun.write(worktree.marker, "done 8 1700000000001\n");
    const newFailure = await callToolCall(host, event, context);

    // #then each distinct failure line reaches pi once
    expect([first, acknowledged, newFailure]).toEqual([
      { block: true, reason: firstReason },
      undefined,
      { block: true, reason: secondReason },
    ]);
  });

  test("the known-bad bash fixture is denied with the policy's prefixed reason", async () => {
    // #given the shipped known-bad zsh command in pi's wire shape
    const fixture = policyFixture("zsh-reserved-name-guard", "zsh/flags the status capture idiom");
    const host = await loadExtension(CORE_DIR);

    // #when the handler sees it
    const decision = await callToolCall(host, piRawFor(fixture));

    // #then pi's own deny envelope carries the core's reason verbatim. The
    // prefix contract on that reason belongs to the core's R9 test, which can
    // observe it for every block-capable policy; asserting it here would only
    // restate a property of the corpus entry this test just loaded.
    expect(decision).toEqual({ block: true, reason: fixture.text });
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

describe("openai-codex tool_call dialect (R3)", () => {
  test("exec_command is denied from its observed input.cmd wire shape", async () => {
    // #given the shipped known-bad command in pi-codex-conversion's wire shape
    const policy = policyFixture("zsh-reserved-name-guard", "zsh/flags the status capture idiom");
    const fixture = corpus.fixture("codex exec command");
    const host = await loadExtension(CORE_DIR);

    // Setup, not an assertion: `policy.text` is only the right expected value
    // below while the two corpus entries carry the same command.
    if (fixture.payload.command !== policy.payload.command) {
      throw new Error("the codex and policy fixtures no longer share one command");
    }

    // #when the handler receives the provider's real tool spelling and field
    const decision = await callToolCall(host, fixture.raw.pi);

    // #then the same policy and reason reached by builtin bash deny the call
    expect(decision).toEqual({ block: true, reason: policy.text });
  });

  test("exec_command allows the nearby ordinary-variable control", async () => {
    // #given the same codex wire shape with a name zsh does not reserve
    const policy = policyFixture(
      "zsh-reserved-name-guard",
      "zsh/an ordinary name zsh accepts is not blocked",
    );

    const fixture = corpus.fixture("codex exec command");
    const raw = { ...fixture.raw.pi, input: { cmd: policy.payload.command } };
    const host = await loadExtension(CORE_DIR);

    // #when it reaches the same handler
    const decision = await callToolCall(host, raw);

    // #then pi reads the absent return as allow
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
        // `shared` holds only the bash and fff-grep fixtures, so allow is the
        // one non-block outcome here: a stray context decision is a defect,
        // not something this branch may accept.
        expect(claudeDecision).toEqual({ verdict: "allow" });
      }
    }

    // Both branches reached, and each for its whole share of the corpus.
    expect([denials, clearances]).toEqual([9, 10]);
  });

  test("the fff route pi exposes denies a multi-token query and allows one identifier", async () => {
    // #given the deny and control in pi-fff's observed wire shape
    const denied = policyFixture("fff-grep-guard", "fff/multi-token bare query is denied");
    const allowed = policyFixture("fff-grep-guard", "fff/single identifier passes");
    const host = await loadExtension(CORE_DIR);

    // #when both go through pi-fff's default tool spelling and argument dialect
    const deniedDecision = await callToolCall(host, {
      toolName: "ffgrep",
      input: { pattern: denied.payload.query },
    });

    const allowedDecision = await callToolCall(host, {
      toolName: "ffgrep",
      input: { pattern: allowed.payload.query },
    });

    // #then only the multi-token query is refused
    expect(deniedDecision).toEqual({ block: true, reason: denied.text });
    expect(allowedDecision).toBeUndefined();
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

  test("a dispatch that throws at call time still lets the tool call proceed", async () => {
    // #given a core that imports cleanly but whose dispatch throws
    const throwing = temporaryDir("agent-hooks-throwing-core-");
    await Bun.write(
      join(throwing, "index.ts"),
      "export function dispatch() { throw new Error('policy exploded'); }\n",
    );
    const host = await loadExtension(throwing);

    // #when a known-bad command reaches the registered handler
    const fixture = policyFixture("zsh-reserved-name-guard", "zsh/blocks status");
    const decision = await callToolCall(host, piRawFor(fixture));

    // #then the handler exists and the call is allowed through: R4 requires a
    // dispatch exception to fail open rather than to reach pi as a throw, which
    // is not a deny in pi's contract.
    expect(host.events).toEqual(["tool_call"]);
    expect(decision).toBeUndefined();
  });
});
