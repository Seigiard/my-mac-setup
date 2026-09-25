import { afterEach, describe, expect, test } from "bun:test";
import { cpSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const CORE_DIR =
  process.env.AGENT_HOOKS_CORE_PATH ?? join(import.meta.dir, "../home/dot_local/lib/agent-hooks");

const core: any = await import(join(CORE_DIR, "index.ts"));
const normalize: any = await import(join(CORE_DIR, "normalize.ts"));
const selfcheck: any = await import(join(CORE_DIR, "selfcheck.ts"));
const corpus: any = await import(join(CORE_DIR, "fixtures.ts"));

const CLIENTS = ["claude", "opencode", "pi"] as const;
const temporaryPaths: string[] = [];

function temporaryDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  temporaryPaths.push(dir);
  return dir;
}

afterEach(() => {
  for (const path of temporaryPaths.splice(0)) rmSync(path, { recursive: true, force: true });
});

// --- fixture policies -------------------------------------------------------
//
// U1 ships no real policies, so every registry-driven scenario below runs
// against this injected set. U2 registers the real policies and inherits the
// same coverage without new test code.

const RESERVED_COMMAND = "status=$? && exit $status";
const BARE_QUERY = "two bare tokens";

type Invocations = Record<string, number>;

function countingPolicy(policy: any, invocations: Invocations): any {
  invocations[policy.name] = 0;
  return {
    ...policy,
    evaluate: (event: any) => {
      invocations[policy.name] += 1;
      return policy.evaluate(event);
    },
  };
}

function reservedNameGuard(): any {
  return {
    name: "fixture-reserved-guard",
    tools: ["bash"],
    outcomes: ["block"],
    escapeHatch: "fixture-ok:",
    canary: { tool: "bash", payload: { command: RESERVED_COMMAND } },
    evaluate: (event: any) => {
      if (event.command.includes("fixture-ok:")) return undefined;
      if (!event.command.includes("status=")) return undefined;
      return core.block(
        `fixture-reserved-guard: this command assigns to a parameter zsh reserves. ` +
          `Use rc=$? instead, or prefix the command with fixture-ok: to override.`,
      );
    },
  };
}

function contentGuard(): any {
  return {
    name: "fixture-content-guard",
    tools: ["write", "edit"],
    outcomes: ["block"],
    canary: { tool: "write", payload: { filePath: "/repo/tests/a_test.sh", content: "assert_absent x" } },
    evaluate: (event: any) => {
      if (!event.content.includes("assert_absent")) return undefined;
      return core.block(
        `fixture-content-guard: an absence assertion has no oracle here. ` +
          `Assert the capability that remains, or exercise the real transition instead.`,
      );
    },
  };
}

function contextOnlyPolicy(): any {
  return {
    name: "fixture-context-hint",
    tools: ["bash"],
    outcomes: ["context"],
    evaluate: () => core.context("fixture-context-hint: consider the shorter path first."),
  };
}

function throwingPolicy(): any {
  return {
    name: "fixture-throws",
    tools: ["bash"],
    outcomes: ["block"],
    canary: { tool: "bash", payload: { command: RESERVED_COMMAND } },
    evaluate: () => {
      throw new Error("policy blew up on this input");
    },
  };
}

function registryWith(policies: any[]): any {
  return core.createRegistry({ policies });
}

const TEST_REGISTRY = registryWith([reservedNameGuard(), contentGuard(), contextOnlyPolicy()]);

// --- scenario 1: dialect normalization --------------------------------------

describe("normalization of the three arg dialects", () => {
  test("every dialect of a fixture normalizes to one canonical payload", () => {
    // #given the shared corpus, written in the wire shapes the shipped adapters read
    expect(corpus.DIALECT_FIXTURES.length).toBeGreaterThan(3);

    for (const fixture of corpus.DIALECT_FIXTURES) {
      const expected = { ...core.emptyPayload(), ...fixture.payload };
      const clients = Object.keys(fixture.raw);
      expect(clients.length).toBeGreaterThan(0);

      for (const client of clients) {
        // #when the client's raw event goes through the core normalizer
        const event = normalize.normalizeEvent(client, fixture.raw[client], TEST_REGISTRY);

        // #then the canonical payload and tool kind are identical across dialects
        expect(`${fixture.name}/${client}: ${event?.tool}`).toBe(`${fixture.name}/${client}: ${fixture.tool}`);
        expect(core.payloadOf(event)).toEqual(expected);
      }
    }
  });

  test("a full-file write reaches the policies through content alone", () => {
    // #given a Write-shaped fixture whose text lives only in `content`
    const fixture = corpus.fixture("write with content only");
    expect(Object.keys(fixture.raw).sort()).toEqual([...CLIENTS].sort());

    // #when each dialect is normalized
    const contents = CLIENTS.map(
      (client) => normalize.normalizeEvent(client, fixture.raw[client], TEST_REGISTRY).content,
    );

    // #then all three carry the same non-empty content
    expect(contents[0]).toBe(fixture.payload.content);
    expect(new Set(contents).size).toBe(1);
  });

  test("an unmapped tool or malformed event normalizes to nothing", () => {
    // #given events the registry has no tool mapping for
    const unmapped = { tool_name: "Glob", tool_input: { pattern: "*" } };

    // #when and #then normalization declines rather than inventing an event
    expect(normalize.normalizeEvent("claude", unmapped, TEST_REGISTRY)).toBeUndefined();
    expect(normalize.normalizeEvent("claude", null, TEST_REGISTRY)).toBeUndefined();
    expect(normalize.normalizeEvent("nosuchclient", {}, TEST_REGISTRY)).toBeUndefined();
  });
});

// --- scenario 2: first deny wins --------------------------------------------

describe("dispatch ordering", () => {
  test("the first deny stops later policies from running", () => {
    // #given two denying policies for the same tool, in declaration order
    const invocations: Invocations = {};
    const deny = (name: string) => ({
      name,
      tools: ["bash"],
      outcomes: ["block"],
      canary: { tool: "bash", payload: { command: RESERVED_COMMAND } },
      evaluate: () => core.block(`${name}: denied. Use a different command instead.`),
    });
    const first = countingPolicy(deny("fixture-deny-first"), invocations);
    const second = countingPolicy(deny("fixture-deny-second"), invocations);
    const registry = registryWith([first, second]);

    // #when a command both would deny is dispatched
    const trace = core.dispatchTraced("claude", corpus.fixture("bash command").raw.claude, {
      registry,
      env: {},
    });

    // #then only the first ran and its reason is the verdict
    expect(trace.decision).toEqual({
      verdict: "block",
      reason: "fixture-deny-first: denied. Use a different command instead.",
    });
    expect(trace.invoked).toEqual(["fixture-deny-first"]);
    expect(invocations["fixture-deny-second"]).toBe(0);
  });
});

// --- scenario 3: fail-open bias, pinned by mutation -------------------------

describe("fail-open bias (R4)", () => {
  // Calibrated by mutation on 2026-09-25: replacing the `decision = ALLOW;`
  // line in runPolicies' catch clause (index.ts) with a block makes this test
  // fail with `Expected: "allow" / Received: "block"`. The mutation is a
  // one-time red-state proof, not a permanent test: a resident copy of it
  // greps index.ts for one exact line and breaks on any harmless re-indent or
  // rename while proving nothing about the shipped core.
  test("a policy that throws yields allow", () => {
    // #given a policy that raises on the event
    const registry = registryWith([throwingPolicy()]);

    // #when it is dispatched
    const decision = core.dispatch("pi", corpus.fixture("bash command").raw.pi, { registry, env: {} });

    // #then the tool call proceeds
    expect(decision).toEqual({ verdict: "allow" });
  });
});

// --- scenario 4: AGENT_HOOKS_DISABLE ----------------------------------------

describe("AGENT_HOOKS_DISABLE (R8)", () => {
  const bashEvent = corpus.fixture("bash command").raw.claude;
  const registry = registryWith([reservedNameGuard()]);

  test("disabling by name skips exactly that policy", () => {
    // #given the policy named in the process environment
    // #when the guarded command is dispatched
    const disabled = core.dispatch("claude", bashEvent, {
      registry,
      env: { AGENT_HOOKS_DISABLE: "fixture-reserved-guard" },
    });
    const other = core.dispatch("claude", bashEvent, {
      registry,
      env: { AGENT_HOOKS_DISABLE: "fixture-content-guard" },
    });

    // #then only the named policy stops enforcing
    expect(disabled.verdict).toBe("allow");
    expect(other.verdict).toBe("block");
  });

  test("an unknown policy name is ignored", () => {
    // #given a name no policy carries
    // #when dispatching
    const decision = core.dispatch("claude", bashEvent, {
      registry,
      env: { AGENT_HOOKS_DISABLE: "no-such-policy, " },
    });

    // #then enforcement is unchanged
    expect(decision.verdict).toBe("block");
  });

  test("the assignment inside the intercepted command disables nothing", () => {
    // #given the disable assignment appearing in the tool call's own command text
    const selfDisabling = {
      tool_name: "Bash",
      tool_input: { command: `AGENT_HOOKS_DISABLE=fixture-reserved-guard ${RESERVED_COMMAND}` },
    };

    // #when it is dispatched with a clean environment
    const decision = core.dispatch("claude", selfDisabling, { registry, env: {} });

    // #then the policy still denies: only the process environment is read
    expect(decision).toEqual({
      verdict: "block",
      reason:
        "fixture-reserved-guard: this command assigns to a parameter zsh reserves. " +
        "Use rc=$? instead, or prefix the command with fixture-ok: to override.",
    });
  });
});

// --- scenario 5: applicability derivation (KTD8) ----------------------------

describe("applicability derivation", () => {
  test("a pair with no applicable policy allows without invoking a policy", () => {
    // #given a registry whose only policy watches bash
    const invocations: Invocations = {};
    const registry = registryWith([countingPolicy(reservedNameGuard(), invocations)]);

    // #when a write event is dispatched
    const trace = core.dispatchTraced("opencode", corpus.fixture("write with content only").raw.opencode, {
      registry,
      env: {},
    });

    // #then the call proceeds and nothing ran
    expect(trace.decision.verdict).toBe("allow");
    expect(trace.invoked).toEqual([]);
    expect(invocations["fixture-reserved-guard"]).toBe(0);
  });

  test("a context-only policy is inapplicable where the outcome is unsupported", () => {
    // #given a policy whose only outcome is context, on a tool every client has
    const invocations: Invocations = {};
    const policy = countingPolicy(contextOnlyPolicy(), invocations);
    const registry = registryWith([policy]);
    const fixture = corpus.fixture("bash command");

    // #when the same command is dispatched through each client
    const decisions = CLIENTS.map((client) =>
      core.dispatch(client, fixture.raw[client], { registry, env: {} }),
    );

    // #then only the profile that supports context runs it at all
    expect(decisions[0].verdict).toBe("context");
    expect(decisions[1].verdict).toBe("allow");
    expect(decisions[2].verdict).toBe("allow");
    expect(invocations["fixture-context-hint"]).toBe(1);
    expect(core.applicableClients(registry, policy)).toEqual(["claude"]);
  });

  test("the fff grep policy is applicable through every shipped profile", () => {
    // #given a block policy for the fff grep tool
    const policy = {
      name: "fixture-query-guard",
      tools: ["fff-grep"],
      outcomes: ["block"],
      evaluate: () => core.block("fixture-query-guard: unreachable in this test."),
    };

    // #when applicability is derived
    const clients = core.applicableClients(registryWith([policy]), policy);

    // #then each verified spelling is declared statically
    expect(clients).toEqual(["claude", "opencode", "pi"]);
  });
});

// --- scenario 6: cross-client decision parity -------------------------------

describe("cross-client parity (KTD8)", () => {
  test("every multi-client policy yields one verdict and one reason everywhere", () => {
    // #given each registry policy applicable in more than one client
    const registries = [TEST_REGISTRY, core.CORE_REGISTRY];
    let compared = 0;

    for (const registry of registries) {
      for (const policy of registry.policies) {
        const clients = core.applicableClients(registry, policy);
        if (clients.length < 2 || !policy.canary) continue;

        // #when its canary fixture is encoded into each applicable dialect
        const decisions = clients.map((client: string) => {
          const raw = normalize.encodeEvent(client, policy.canary.tool, policy.canary.payload, registry);
          expect(raw).toBeDefined();
          return core.dispatch(client, raw, { registry, env: {} });
        });

        // #then the decision object is identical across dialects
        for (const decision of decisions) expect(decision).toEqual(decisions[0]);
        compared += 1;
      }
    }

    expect(compared).toBeGreaterThanOrEqual(2);
  });
});

// --- scenario 7: reason contract (R9) ---------------------------------------

describe("reason contract (R9)", () => {
  // The exact reason text of every shipped policy is owned by the corpus loop
  // below. What R9 adds here is the two properties that hold for any policy:
  // the reason opens with the policy's own name, and a policy that declares an
  // escape hatch repeats that token in the reason it denies with.
  test("every block-capable policy names itself and repeats its escape hatch", () => {
    // #given the block-capable policies of each registry
    const registries = [TEST_REGISTRY, core.CORE_REGISTRY];
    const observed: string[] = [];

    for (const registry of registries) {
      for (const policy of registry.policies) {
        if (!core.isBlockCapable(policy)) continue;
        const canary = policy.canary ?? { tool: "no-canary-declared", payload: {} };
        for (const client of core.applicableClients(registry, policy)) {
          const raw = normalize.encodeEvent(client, canary.tool, canary.payload, registry);

          // #when the known-bad canary is dispatched
          const decision = core.dispatch(client, raw, { registry, env: {} });

          // #then every route denies, names itself, and repeats its own hatch
          const hatch =
            policy.escapeHatch === undefined
              ? "none"
              : String(decision.reason?.includes(policy.escapeHatch));
          observed.push(
            `${policy.name}@${client}: ${decision.verdict}` +
              ` prefixed=${decision.reason?.startsWith(`${policy.name}:`)}` +
              ` hatch=${hatch}`,
          );
        }
      }
    }

    expect(observed).toEqual([
      "fixture-reserved-guard@claude: block prefixed=true hatch=true",
      "fixture-reserved-guard@opencode: block prefixed=true hatch=true",
      "fixture-reserved-guard@pi: block prefixed=true hatch=true",
      "fixture-content-guard@claude: block prefixed=true hatch=none",
      "fixture-content-guard@opencode: block prefixed=true hatch=none",
      "fixture-content-guard@pi: block prefixed=true hatch=none",
      "zsh-reserved-name-guard@claude: block prefixed=true hatch=true",
      "zsh-reserved-name-guard@opencode: block prefixed=true hatch=true",
      "zsh-reserved-name-guard@pi: block prefixed=true hatch=true",
      "fff-grep-guard@claude: block prefixed=true hatch=none",
      "fff-grep-guard@opencode: block prefixed=true hatch=none",
      "fff-grep-guard@pi: block prefixed=true hatch=none",
    ]);
  });
});

// --- scenario 8: layering (KTD1) --------------------------------------------

const CLIENT_NAME_PATTERN = /\b(claude|opencode|pi)\b/i;

function policyModules(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true, recursive: true } as any)
    .filter((entry: any) => entry.isFile() && entry.name.endsWith(".ts"))
    .map((entry: any) => join(entry.parentPath ?? entry.path ?? dir, entry.name));
}

function clientNameViolations(dir: string): string[] {
  return policyModules(dir).filter((path) => CLIENT_NAME_PATTERN.test(readFileSync(path, "utf8")));
}

describe("layering (KTD1)", () => {
  // Control, not coverage: the unit under test here is this file's own
  // `clientNameViolations` helper. It exists so that the empty result of the
  // next test is a discriminating verdict rather than a scanner that reports
  // nothing whatever it reads.
  test("the scan detects a policy module that names a client", () => {
    // #given one compliant and one offending policy module
    const dir = temporaryDir("agent-hooks-layering-");
    writeFileSync(join(dir, "clean.ts"), "export const policy = { name: 'x', tools: ['bash'] };\n");
    writeFileSync(join(dir, "leaky.ts"), "// only applies on OpenCode\nexport const policy = {};\n");

    // #when the directory is scanned
    const violations = clientNameViolations(dir);

    // #then exactly the offender is reported
    expect(violations.map((path) => path.endsWith("leaky.ts"))).toEqual([true]);
  });

  // A layering lint over source text, not a behavior test: the literal shape
  // *is* the contract KTD1 states. Its two known limits: `\bpi\b` also flags a
  // harmless mention in a comment, and client knowledge spelled without the
  // word (a tool name such as `mcp__fff__grep`) passes. It belongs with
  // `make lint` rather than here once shellcheck gains a TypeScript sibling.
  test("no shipped policy module references a client", () => {
    // #given the core's policy directory
    const dir = join(CORE_DIR, "policies");
    expect(policyModules(dir).length).toBeGreaterThan(0);

    // #when it is scanned
    // #then nothing names a client: client knowledge lives in the registry only
    expect(clientNameViolations(dir)).toEqual([]);
  });
});

// --- scenario 9: selfcheck ---------------------------------------------------

describe("selfcheck canary", () => {
  test("a live route blocks and a dead one is reported as a failure", () => {
    // #given one policy that enforces and one whose canary no longer trips it
    const live = reservedNameGuard();
    const dead = {
      ...contentGuard(),
      name: "fixture-dead-route",
      evaluate: () => undefined,
    };

    // #when the registry-derived canaries run
    const results = selfcheck.runCanaries(registryWith([live, dead]));

    // #then every route of the live policy blocks and every dead route is named
    expect(
      results.map((result: any) => `${result.policy}@${result.client}: ${result.ok} ${result.detail}`),
    ).toEqual([
      "fixture-reserved-guard@claude: true blocked",
      "fixture-reserved-guard@opencode: true blocked",
      "fixture-reserved-guard@pi: true blocked",
      "fixture-dead-route@claude: false expected block, got allow",
      "fixture-dead-route@opencode: false expected block, got allow",
      "fixture-dead-route@pi: false expected block, got allow",
    ]);
  });

  test("a session-level disable cannot make a dead route look alive", () => {
    // #given the selfcheck process itself running with the policy disabled
    const registry = registryWith([reservedNameGuard()]);
    const previous = process.env.AGENT_HOOKS_DISABLE;
    process.env.AGENT_HOOKS_DISABLE = "fixture-reserved-guard";
    try {
      // #when the canaries run, and the same event is dispatched with the
      // process environment the canary deliberately ignores
      const results = selfcheck.runCanaries(registry);
      const withProcessEnv = core.dispatch("claude", corpus.fixture("bash command").raw.claude, {
        registry,
        env: process.env,
      });

      // #then the disable was live in this process, and the canary blocked anyway
      expect(withProcessEnv).toEqual({ verdict: "allow" });
      expect(
        results.map((result: any) => `${result.policy}@${result.client}: ${result.ok} ${result.detail}`),
      ).toEqual([
        "fixture-reserved-guard@claude: true blocked",
        "fixture-reserved-guard@opencode: true blocked",
        "fixture-reserved-guard@pi: true blocked",
      ]);
    } finally {
      if (previous === undefined) delete process.env.AGENT_HOOKS_DISABLE;
      else process.env.AGENT_HOOKS_DISABLE = previous;
    }
  });
});

describe("selfcheck loaded-identity markers (KTD5)", () => {
  const DEPLOYED = "deployedhash000";
  const OLD = "oldhash111";
  const alive = (pids: number[]) => (pid: number) => pids.includes(pid);

  function inspect(stateDir: string, isAlive: (pid: number) => boolean) {
    return selfcheck.inspectIdentity({
      stateDir,
      deployedHash: DEPLOYED,
      clients: ["claude", "opencode", "pi"],
      markerlessClients: ["claude"],
      isAlive,
    });
  }

  function statusOf(report: any, client: string) {
    return report.clients.find((entry: any) => entry.client === client);
  }

  test("no live marker reports unknown, never current", () => {
    // #given a state dir with no markers
    const stateDir = temporaryDir("agent-hooks-state-");

    // #when identity is inspected
    const report = inspect(stateDir, () => true);

    // #then resident clients are unknown and nothing claims to be current
    expect(statusOf(report, "opencode").status).toBe("unknown");
    expect(statusOf(report, "pi").status).toBe("unknown");
    expect(report.clients.some((entry: any) => entry.status === "current")).toBe(false);
  });

  test("a live marker older than the deployed core names the stale session", () => {
    // #given one stale and one current live session
    const stateDir = temporaryDir("agent-hooks-state-");
    selfcheck.writeMarker("opencode", { stateDir, pid: 4242, hash: OLD });
    selfcheck.writeMarker("opencode", { stateDir, pid: 4243, hash: DEPLOYED });
    selfcheck.writeMarker("pi", { stateDir, pid: 4244, hash: DEPLOYED });

    // #when identity is inspected with both processes alive
    const report = inspect(stateDir, alive([4242, 4243, 4244]));

    // #then the stale session is named and the fully current client says so
    expect(statusOf(report, "opencode").status).toBe("stale");
    expect(statusOf(report, "opencode").stale.map((marker: any) => marker.pid)).toEqual([4242]);
    expect(statusOf(report, "pi").status).toBe("current");
  });

  test("a dead process's marker is not evidence", () => {
    // #given a stale marker whose process has exited
    const stateDir = temporaryDir("agent-hooks-state-");
    selfcheck.writeMarker("opencode", { stateDir, pid: 4242, hash: OLD });

    // #when identity is inspected with that pid dead
    const report = inspect(stateDir, alive([]));

    // #then the marker is ignored and the client falls back to unknown
    expect(statusOf(report, "opencode").status).toBe("unknown");
    expect(statusOf(report, "opencode").live).toEqual([]);
  });

  test("the per-call client is never given a loaded identity", () => {
    // #given a state dir holding no marker for the subprocess client
    const stateDir = temporaryDir("agent-hooks-state-");

    // #when identity is inspected
    const report = inspect(stateDir, () => true);

    // #then it reports per-call rather than borrowing another client's evidence
    expect(statusOf(report, "claude").status).toBe("per-call");
  });

  test("the deployed hash changes when the core changes", () => {
    // #given a copy of the deployed core
    const dir = temporaryDir("agent-hooks-hash-");
    cpSync(CORE_DIR, dir, { recursive: true });
    const before = selfcheck.coreHash(dir);

    // #when one core file changes
    writeFileSync(join(dir, "registry.ts"), `${readFileSync(join(dir, "registry.ts"), "utf8")}\n// drift\n`);

    // #then the identity a marker records differs
    expect(selfcheck.coreHash(dir)).not.toBe(before);
  });
});

describe("selfcheck report", () => {
  test("the JSON entry point exposes the registry the union test consumes", () => {
    // #given the shipped registry
    const snapshot = core.registrySnapshot(core.CORE_REGISTRY);

    // #when the client profiles are read back
    const claude = snapshot.clients.find((entry: any) => entry.client === "claude");

    // #then the whole profile survives the JSON round-trip, spelling for spelling
    expect(JSON.parse(JSON.stringify(snapshot))).toEqual(snapshot);
    expect(claude.tools).toEqual({
      Edit: "edit",
      MultiEdit: "edit",
      Write: "write",
      Bash: "bash",
      mcp__fff__grep: "fff-grep",
      WebFetch: "web-fetch",
    });
    expect(claude.outcomes).toEqual(["block", "context"]);
    expect(snapshot.clients.map((entry: any) => entry.client)).toEqual([...CLIENTS]);
  });

  test("the human-readable report names each failing route", () => {
    // #given a registry with one dead route
    const registry = registryWith([{ ...contentGuard(), name: "fixture-dead-route", evaluate: () => undefined }]);

    // #when the report is rendered
    const report = selfcheck.selfcheck(registry, { stateDir: temporaryDir("agent-hooks-state-") });
    const text = selfcheck.formatReport(report);

    // #then the report is not ok and every dead route has its own line.
    // The first three lines carry the core path, the bun version and the
    // deployed hash, which are properties of the machine rather than of the
    // registry under test; everything below them is fixed by this fixture.
    expect(report.ok).toBe(false);
    expect(text.split("\n").slice(3)).toEqual([
      "policies: 1",
      "canaries:",
      "  [FAIL] fixture-dead-route @ claude: expected block, got allow",
      "  [FAIL] fixture-dead-route @ opencode: expected block, got allow",
      "  [FAIL] fixture-dead-route @ pi: expected block, got allow",
      "loaded identity:",
      "  claude: per-call",
      "  opencode: unknown",
      "  pi: unknown",
      "result: FAILED",
    ]);
  });
});

// --- scenario 10: the ported policy corpus (U2, KTD3) -----------------------
//
// The fixtures come from the two bashunit suites that predate the port, plus
// the two inline hook rules; the expected strings are transcribed from the
// shipped engines' stdout. Both sides of every comparison below are therefore
// independent of the policy modules under test.

function policyByName(name: string): any {
  const found = core.CORE_REGISTRY.policies.find((policy: any) => policy.name === name);
  if (!found) throw new Error(`policy not registered in CORE_POLICIES: ${name}`);
  return found;
}

function dispatchFixture(fixture: any): any[] {
  const policy = policyByName(fixture.policy);
  const clients = core.applicableClients(core.CORE_REGISTRY, policy);
  expect(clients.length).toBeGreaterThan(0);
  return clients.map((client: string) => {
    const raw = normalize.encodeEvent(client, fixture.tool, fixture.payload, core.CORE_REGISTRY);
    expect(raw).toBeDefined();
    return core.dispatch(client, raw, { registry: core.CORE_REGISTRY, env: {} });
  });
}

// Registry membership is not frozen by a list here: `policyByName` throws for
// every fixture whose policy is missing, the canary test below pins the exact
// block-capable route set, and the applicability test pins webfetch's.
describe("ported policy corpus (KTD3)", () => {
  for (const fixture of corpus.POLICY_FIXTURES) {
    test(fixture.name, () => {
      // #given a fixture translated from the pre-existing corpus
      // #when it is dispatched through every client route the registry derives
      const decisions = dispatchFixture(fixture);

      // #then every route reaches the shipped verdict and the shipped text
      for (const decision of decisions) {
        expect(`${fixture.name}: ${decision.verdict}`).toBe(`${fixture.name}: ${fixture.verdict}`);
        if (fixture.verdict === "block") expect(decision.reason).toBe(fixture.text);
        if (fixture.verdict === "context") expect(decision.text).toBe(fixture.text);
        expect(decision).toEqual(decisions[0]);
      }
    });
  }
});

describe("escape hatches (KTD3)", () => {
  test("removing the escape token flips each escaped fixture to a deny", () => {
    // #given the fixture the corpus expects to pass only because it is escaped
    const escaped = [
      { fixture: corpus.fixture, name: "zsh/zsh-ok comment releases the command", field: "command", token: "zsh-ok:" },
    ];

    for (const entry of escaped) {
      const original = corpus.POLICY_FIXTURES.find((candidate: any) => candidate.name === entry.name);
      expect(original.verdict).toBe("allow");
      expect(policyByName(original.policy).escapeHatch).toBe(entry.token);

      // #when the escape token alone is replaced by an ordinary word
      const mutated = {
        ...original,
        payload: {
          ...original.payload,
          [entry.field]: original.payload[entry.field].replace(entry.token, "note-only:"),
        },
      };
      const decisions = dispatchFixture(mutated);

      // #then the same content denies, so the token is what admitted it
      for (const decision of decisions) {
        expect(`${entry.name}: ${decision.verdict}`).toBe(`${entry.name}: block`);
        expect(decision.reason).toContain(entry.token);
      }
    }
  });
});

describe("fff-grep-guard fail-open (R4)", () => {
  test("a non-string query reaches the policy as empty text and allows", () => {
    // #given a wire event whose query field is not a string
    const malformed = { tool_name: "mcp__fff__grep", tool_input: { query: 42 } };

    // #when it is dispatched
    const trace = core.dispatchTraced("claude", malformed, {
      registry: core.CORE_REGISTRY,
      env: {},
    });

    // #then the normalizer coerced the number to "" rather than declining the
    // event, the guard still ran on it, and the call proceeds
    expect(trace.invoked).toEqual(["fff-grep-guard"]);
    expect(trace.decision).toEqual({ verdict: "allow" });
  });
});

describe("webfetch-markdown-hint applicability (KTD8)", () => {
  test("the context-only policy is derived Claude-only", () => {
    // #given the shipped registry
    // #when applicability is derived for the hint policy
    const clients = core.applicableClients(core.CORE_REGISTRY, policyByName("webfetch-markdown-hint"));

    // #then only the profile that can express additionalContext carries it
    expect(clients).toEqual(["claude"]);
  });

  test("a profile that has the tool but not the outcome never runs it", () => {
    // #given a profile carrying a web-fetch spelling but only the block outcome
    const policy = policyByName("webfetch-markdown-hint");
    let calls = 0;
    const counted = { ...policy, evaluate: (event: any) => { calls += 1; return policy.evaluate(event); } };
    const base = core.CORE_REGISTRY.profiles.find((profile: any) => profile.client === "opencode");
    const registry = core.createRegistry({
      policies: [counted],
      profiles: [{ ...base, tools: { ...base.tools, webfetch: "web-fetch" }, outcomes: ["block"] }],
    });

    // #when a hint-worthy url is dispatched there
    const raw = normalize.encodeEvent("opencode", "web-fetch", { url: "https://example.com/docs" }, registry);
    const decision = core.dispatch("opencode", raw, { registry, env: {} });

    // #then the policy never ran and the call proceeds
    expect(decision.verdict).toBe("allow");
    expect(calls).toBe(0);
  });

  // The verdict of every hint fixture is asserted exactly by the corpus loop
  // above; what remains here is the declaration that keeps the policy off the
  // block path — and out of the selfcheck canary set — in the first place.
  test("the hint policy is not block-capable, so it can never deny", () => {
    // #given the shipped hint policy
    const policy = policyByName("webfetch-markdown-hint");

    // #when its outcomes are read
    // #then block is not among them
    expect(policy.outcomes).toEqual(["context"]);
    expect(core.isBlockCapable(policy)).toBe(false);
  });
});

// --- scenario 11: selfcheck canary over the shipped policies ----------------

describe("selfcheck canary over the shipped registry (R8)", () => {
  test("every block-capable route of the shipped registry blocks", () => {
    // #given the shipped registry
    // #when its registry-derived canaries run
    const results = selfcheck.runCanaries(core.CORE_REGISTRY);

    // #then every derived route exists and blocks
    expect(results.map((result: any) => `${result.policy}@${result.client}`).sort()).toEqual([
      "fff-grep-guard@claude",
      "fff-grep-guard@opencode",
      "fff-grep-guard@pi",
      "zsh-reserved-name-guard@claude",
      "zsh-reserved-name-guard@opencode",
      "zsh-reserved-name-guard@pi",
    ]);
    expect(results.filter((result: any) => !result.ok).map((result: any) => `${result.policy}@${result.client}: ${result.detail}`)).toEqual([]);
  });

  test("a deliberately broken route is reported as a failure", () => {
    // #given the shipped registry with one policy's evaluation removed
    const broken = core.CORE_REGISTRY.policies.map((policy: any) =>
      policy.name === "zsh-reserved-name-guard" ? { ...policy, evaluate: () => undefined } : policy,
    );

    // #when the canaries run against it
    const results = selfcheck.runCanaries(core.createRegistry({ policies: broken }));

    // #then exactly that policy's routes are named as failures
    const failures = results.filter((result: any) => !result.ok);
    expect(failures.map((result: any) => `${result.policy}@${result.client}`)).toEqual([
      "zsh-reserved-name-guard@claude",
      "zsh-reserved-name-guard@opencode",
      "zsh-reserved-name-guard@pi",
    ]);
    expect(failures[0].detail).toBe("expected block, got allow");
  });
});
