import { afterEach, describe, expect, test } from "bun:test";
import {
  chmodSync,
  cpSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const PLUGIN_PATH =
  process.env.HERDR_RESOURCE_CONTEXT_OPENCODE_PLUGIN_PATH ??
  join(import.meta.dir, "../home/private_dot_config/opencode/plugins/herdr-resource-context.ts");

const HEADING = "## Herdr Agent Resource Context (generated)";

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

type Transform = (
  input: { sessionID?: string },
  output: { system: string[] },
) => Promise<void>;

type V2RequestKind = "context" | "compaction" | "generate" | "title";

type V2ContextHook = (event: { sessionID: string; system: Array<{ type: "text"; text: string }> }) => Promise<void> | void;

function installQueryStub(root: string): string {
  const cli = join(root, "herdr-resource-tree");
  writeFileSync(
    cli,
    `#!/bin/sh
root=${JSON.stringify(root)}
printf '%s\\n' "$@" > ${JSON.stringify(join(root, "query-argv"))}
if [ -f "$root/stderr-$5" ]; then
  cat "$root/stderr-$5" >&2
fi
if [ -f "$root/fail-$5" ]; then
  cat "$root/fail-$5" >&2
  exit 1
fi
if [ -f "$root/context-$5" ]; then
  cat "$root/context-$5"
else
  cat "$root/context"
fi
`,
  );
  chmodSync(cli, 0o755);

  return cli;
}

async function loadV1Plugin(
  root: string,
  herdrEnv = "1",
): Promise<{ hooks: Record<string, Function>; sessionOperations: () => string[] }> {
  const cli = installQueryStub(root);
  const copy = join(temporaryDir("herdr-resource-context-plugin-"), `plugin-${loadCount++}.ts`);
  cpSync(PLUGIN_PATH, copy);

  const previous = {
    HOME: process.env.HOME,
    HERDR_ENV: process.env.HERDR_ENV,
    HERDR_RESOURCE_CONTEXT_CLI: process.env.HERDR_RESOURCE_CONTEXT_CLI,
  };

  process.env.HOME = root;
  process.env.HERDR_ENV = herdrEnv;
  process.env.HERDR_RESOURCE_CONTEXT_CLI = cli;

  const operations: string[] = [];

  try {
    const module: any = await import(copy);

    const hooks: Record<string, Function> =
      (await module.HerdrResourceContextPlugin({
        directory: root,
        worktree: root,
        client: { session: { promptAsync: async () => operations.push("legacy-promptAsync") } },
      })) ?? {};

    return { hooks, sessionOperations: () => operations };
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

async function loadV2Plugin(
  root: string,
  herdrEnv = "1",
): Promise<{ request: (kind: V2RequestKind, sessionID: string | undefined, initial: string[]) => Promise<string[]>; sessionOperations: () => string[] }> {
  const cli = installQueryStub(root);
  const copy = join(temporaryDir("herdr-resource-context-plugin-v2-"), `plugin-${loadCount++}.ts`);
  cpSync(PLUGIN_PATH, copy);

  const previous = {
    HOME: process.env.HOME,
    HERDR_ENV: process.env.HERDR_ENV,
    HERDR_RESOURCE_CONTEXT_CLI: process.env.HERDR_RESOURCE_CONTEXT_CLI,
  };

  process.env.HOME = root;
  process.env.HERDR_ENV = herdrEnv;
  process.env.HERDR_RESOURCE_CONTEXT_CLI = cli;

  const operations: string[] = [];

  try {
    const module: any = await import(copy);
    const hooks: Partial<Record<V2RequestKind, V2ContextHook>> = {};

    await module.default.setup({
      session: {
        hook: async (name: V2RequestKind, hook: V2ContextHook) => {
          hooks[name] = hook;

          return { dispose: async () => {} };
        },
        prompt: async () => {
          operations.push("prompt");
        },
        synthetic: async () => {
          operations.push("synthetic");
        },
      },
    });

    return {
      request: async (kind, sessionID, initial) => {
        const system = initial.map((text) => ({ type: "text" as const, text }));
        const hook = hooks[kind];

        if (hook) await hook({ sessionID: sessionID ?? "", system });

        return system.map((part) => part.text);
      },
      sessionOperations: () => operations,
    };
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

async function loadV1Transform(root: string): Promise<{ transform: Transform; sessionOperations: () => string[] }> {
  const host = await loadV1Plugin(root);
  const transform = host.hooks["experimental.chat.system.transform"];
  expect(transform).toBeTypeOf("function");

  return { transform, sessionOperations: host.sessionOperations };
}

async function loadV2Transform(root: string): Promise<{ transform: Transform; sessionOperations: () => string[] }> {
  const host = await loadV2Plugin(root);

  return {
    transform: async (input, output) => {
      const system = await host.request("context", input.sessionID, output.system);
      output.system.splice(0, output.system.length, ...system);
    },
    sessionOperations: host.sessionOperations,
  };
}

async function loadSharedTransforms(root: string): Promise<{ v1: { transform: Transform; sessionOperations: () => string[] }; v2: { transform: Transform; sessionOperations: () => string[] } }> {
  return { v1: await loadV1Transform(root), v2: await loadV2Transform(root) };
}

describe("OpenCode model-request resource context", () => {
  test("the shared branch projection reaches model input without an extra turn", async () => {
    const root = temporaryDir("herdr-resource-context-");

    const context = [
      'Parent agent: "agent-a"',
      'Descendant agent: "agent-c" [herdr:pi/id/session-C]',
      "Resources:",
      '- workspace "Project" [w1] creator=herdr:opencode/id/session-B',
      '    - pane "owned" [w1:pC] terminal=term-C creator=herdr:opencode/id/session-B',
      "Context truncated. Full branch: `herdr-resource-tree --branch`.",
    ].join("\n");

    writeFileSync(join(root, "context"), context);
    writeFileSync(join(root, "stderr-session-B"), 'Excluded sibling: pane "sibling" [w1:pS]\n');
    const hosts = await loadSharedTransforms(root);
    const v1System = ["You are OpenCode."];
    const v2System = ["You are OpenCode."];

    await hosts.v1.transform({ sessionID: "session-B" }, { system: v1System });
    await hosts.v2.transform({ sessionID: "session-B" }, { system: v2System });

    expect([v1System, v2System]).toEqual([
      ["You are OpenCode.", `${HEADING}\n${context}`],
      ["You are OpenCode.", `${HEADING}\n${context}`],
    ]);
    expect([v1System, v2System].flat().join("\n")).not.toContain("sibling");
    expect(readFileSync(join(root, "query-argv"), "utf8").trim().split("\n")).toEqual([
      "--context",
      "--caller-agent",
      "opencode",
      "--caller-session-id",
      "session-B",
    ]);
    expect([hosts.v1.sessionOperations(), hosts.v2.sessionOperations()]).toEqual([[], []]);
  });

  test("successful refresh replaces duplicates while empty and failed queries stay distinct", async () => {
    const root = temporaryDir("herdr-resource-context-refresh-");
    const fresh = 'Parent agent: "agent-a"\nResources:\n- workspace "owned" [w1]';
    writeFileSync(join(root, "context"), fresh);
    const hosts = await loadSharedTransforms(root);
    const stale = `${HEADING}\nResources:\n- workspace "stale" [old]`;
    const v1System = ["You are OpenCode.", stale, stale];
    const v2System = ["You are OpenCode.", stale, stale];

    await hosts.v1.transform({ sessionID: "session-B" }, { system: v1System });
    await hosts.v2.transform({ sessionID: "session-B" }, { system: v2System });

    expect([v1System, v2System]).toEqual([
      ["You are OpenCode.", `${HEADING}\n${fresh}`],
      ["You are OpenCode.", `${HEADING}\n${fresh}`],
    ]);
    expect([v1System, v2System].flat().join("\n").split(HEADING)).toHaveLength(3);

    writeFileSync(join(root, "context"), "");
    await hosts.v1.transform({ sessionID: "session-B" }, { system: v1System });
    await hosts.v2.transform({ sessionID: "session-B" }, { system: v2System });
    expect([v1System, v2System]).toEqual([["You are OpenCode."], ["You are OpenCode."]]);

    const prior = `${HEADING}\nResources:\n- workspace "last-known" [last]`;
    v1System.push(prior);
    v2System.push(prior);
    writeFileSync(join(root, "fail-session-B"), "snapshot unavailable\n");
    await hosts.v1.transform({ sessionID: "session-B" }, { system: v1System });
    await hosts.v2.transform({ sessionID: "session-B" }, { system: v2System });

    const unavailable = [
      "You are OpenCode.",
      `${HEADING}\nHerdr resource context unavailable: the shared resource query failed. This must not be treated as an empty resource branch.`,
    ];

    expect([v1System, v2System]).toEqual([
      unavailable,
      unavailable,
    ]);
  });

  test("V2 native request kinds re-query the conversation and reject a new pane occupant", async () => {
    const root = temporaryDir("herdr-resource-context-session-");
    const firstBranch = 'Resources:\n- pane "first" [w1:p1]';
    const refreshedBranch = 'Resources:\n- pane "refreshed" [w1:p2]';
    writeFileSync(join(root, "context"), "");
    writeFileSync(join(root, "context-session-B"), firstBranch);
    writeFileSync(join(root, "fail-session-new"), "caller identity changed before context projection\n");
    const v1 = await loadV1Transform(root);
    const v2 = await loadV2Plugin(root);

    const v1First = ["ordinary V1 request"];
    await v1.transform({ sessionID: "session-B" }, { system: v1First });
    const v2First = await v2.request("context", "session-B", ["ordinary V2 request"]);
    expect([v1First, v2First]).toEqual([
      ["ordinary V1 request", `${HEADING}\n${firstBranch}`],
      ["ordinary V2 request", `${HEADING}\n${firstBranch}`],
    ]);

    writeFileSync(join(root, "context-session-B"), refreshedBranch);
    const v1Next = ["next V1 request"];

    await v1.transform({ sessionID: "session-B" }, { system: v1Next });

    const requests = await Promise.all([
      v2.request("context", "session-B", ["primary request"]),
      v2.request("compaction", "session-B", ["compaction request"]),
      v2.request("generate", "session-B", ["generate request"]),
      v2.request("title", "session-B", ["title request"]),
    ]);

    expect([v1Next, ...requests]).toEqual([
      ["next V1 request", `${HEADING}\n${refreshedBranch}`],
      ["primary request", `${HEADING}\n${refreshedBranch}`],
      ["compaction request", `${HEADING}\n${refreshedBranch}`],
      ["generate request", `${HEADING}\n${refreshedBranch}`],
      ["title request", `${HEADING}\n${refreshedBranch}`],
    ]);

    // The query failed for the new occupant, so the reason has to be the failed
    // query, not the "no session identity" text a substring match accepts too.
    const replacement = await v2.request("context", "session-new", ["new conversation"]);
    expect(replacement).toEqual([
      "new conversation",
      `${HEADING}\nHerdr resource context unavailable: the shared resource query failed. This must not be treated as an empty resource branch.`,
    ]);
    expect([v1.sessionOperations(), v2.sessionOperations()]).toEqual([[], []]);
  });

  test("a request without a session identity retracts the earlier branch", async () => {
    const root = temporaryDir("herdr-resource-context-no-session-");
    writeFileSync(join(root, "context"), 'Resources:\n- pane "owned" [w1:p1]');
    const hosts = await loadSharedTransforms(root);

    const v1System = ["You are OpenCode."];
    const v2System = ["You are OpenCode."];
    await hosts.v1.transform({ sessionID: "session-B" }, { system: v1System });
    await hosts.v2.transform({ sessionID: "session-B" }, { system: v2System });
    // Exact, like the other projections in this file: the retraction below is
    // only meaningful if the branch it retracts was rendered whole first.
    expect([v1System, v2System]).toEqual([
      ["You are OpenCode.", `${HEADING}\nResources:\n- pane "owned" [w1:p1]`],
      ["You are OpenCode.", `${HEADING}\nResources:\n- pane "owned" [w1:p1]`],
    ]);

    // sessionID is optional in the plugin API, so an absent one is a supported
    // state. Returning early would leave the previous request's branch in the
    // system prompt, presented as current.
    await hosts.v1.transform({}, { system: v1System });
    await hosts.v2.transform({}, { system: v2System });

    const unavailable = [
      "You are OpenCode.",
      `${HEADING}\nHerdr resource context unavailable: OpenCode did not expose a native session identity. This must not be treated as an empty resource branch.`,
    ];

    expect([v1System, v2System]).toEqual([
      unavailable,
      unavailable,
    ]);
  });

  test("outside Herdr the plugin leaves ordinary OpenCode behavior untouched", async () => {
    const root = temporaryDir("herdr-resource-context-outside-");
    writeFileSync(join(root, "context"), 'Resources:\n- pane "must-not-appear" [w1:p1]');

    const v1 = await loadV1Plugin(root, "");
    const v2 = await loadV2Plugin(root, "");

    expect(v1.hooks).toEqual({});
    expect([v1.sessionOperations(), v2.sessionOperations()]).toEqual([[], []]);
    expect(await v2.request("context", "session-B", ["ordinary request"])).toEqual(["ordinary request"]);
    expect(() => readFileSync(join(root, "query-argv"), "utf8")).toThrow();
  });
});
