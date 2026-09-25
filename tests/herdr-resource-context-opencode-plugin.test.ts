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

async function loadPlugin(
  root: string,
  herdrEnv = "1",
): Promise<{ hooks: Record<string, Function>; promptAsyncCalls: () => number }> {
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

  let calls = 0;
  try {
    const module: any = await import(copy);
    const hooks: Record<string, Function> =
      (await module.HerdrResourceContextPlugin({
        directory: root,
        worktree: root,
        client: { session: { promptAsync: async () => calls++ } },
      })) ?? {};
    return { hooks, promptAsyncCalls: () => calls };
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

async function loadTransform(root: string): Promise<{ transform: Transform; promptAsyncCalls: () => number }> {
  const host = await loadPlugin(root);
  const transform = host.hooks["experimental.chat.system.transform"];
  expect(transform).toBeTypeOf("function");
  return { transform: transform as Transform, promptAsyncCalls: host.promptAsyncCalls };
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
    const host = await loadTransform(root);
    const system = ["You are OpenCode."];

    await host.transform({ sessionID: "session-B" }, { system });

    expect(system).toEqual(["You are OpenCode.", `${HEADING}\n${context}`]);
    expect(system.join("\n")).not.toContain("sibling");
    expect(readFileSync(join(root, "query-argv"), "utf8").trim().split("\n")).toEqual([
      "--context",
      "--caller-agent",
      "opencode",
      "--caller-session-id",
      "session-B",
    ]);
    expect(host.promptAsyncCalls()).toBe(0);
  });

  test("successful refresh replaces duplicates while empty and failed queries stay distinct", async () => {
    const root = temporaryDir("herdr-resource-context-refresh-");
    const fresh = 'Parent agent: "agent-a"\nResources:\n- workspace "owned" [w1]';
    writeFileSync(join(root, "context"), fresh);
    const host = await loadTransform(root);
    const stale = `${HEADING}\nResources:\n- workspace "stale" [old]`;
    const system = ["You are OpenCode.", stale, stale];

    await host.transform({ sessionID: "session-B" }, { system });

    expect(system).toEqual(["You are OpenCode.", `${HEADING}\n${fresh}`]);
    expect(system.join("\n").split(HEADING)).toHaveLength(2);

    writeFileSync(join(root, "context"), "");
    await host.transform({ sessionID: "session-B" }, { system });
    expect(system).toEqual(["You are OpenCode."]);

    const prior = `${HEADING}\nResources:\n- workspace "last-known" [last]`;
    system.push(prior);
    writeFileSync(join(root, "fail-session-B"), "snapshot unavailable\n");
    await host.transform({ sessionID: "session-B" }, { system });
    expect(system).toEqual([
      "You are OpenCode.",
      `${HEADING}\nHerdr resource context unavailable: the shared resource query failed. This must not be treated as an empty resource branch.`,
    ]);
  });

  test("each model request re-queries the same conversation and rejects a new pane occupant", async () => {
    const root = temporaryDir("herdr-resource-context-session-");
    const firstBranch = 'Resources:\n- pane "first" [w1:p1]';
    const refreshedBranch = 'Resources:\n- pane "refreshed" [w1:p2]';
    writeFileSync(join(root, "context"), "");
    writeFileSync(join(root, "context-session-B"), firstBranch);
    writeFileSync(join(root, "fail-session-new"), "caller identity changed before context projection\n");
    const host = await loadTransform(root);

    const first = ["ordinary request"];
    await host.transform({ sessionID: "session-B" }, { system: first });
    expect(first).toEqual(["ordinary request", `${HEADING}\n${firstBranch}`]);

    writeFileSync(join(root, "context-session-B"), refreshedBranch);
    const next = ["next request"];
    await host.transform({ sessionID: "session-B" }, { system: next });
    expect(next).toEqual(["next request", `${HEADING}\n${refreshedBranch}`]);

    // OpenCode exposes no request-kind discriminator here. Ordinary, restored,
    // and compaction model calls all rebuild `system` and invoke this transform.
    const restored = ["restored request"];
    await host.transform({ sessionID: "session-B" }, { system: restored });
    expect(restored).toEqual(["restored request", `${HEADING}\n${refreshedBranch}`]);

    const compaction = ["compaction request"];
    await host.transform({ sessionID: "session-B" }, { system: compaction });
    expect(compaction).toEqual(["compaction request", `${HEADING}\n${refreshedBranch}`]);

    // The query failed for the new occupant, so the reason has to be the failed
    // query, not the "no session identity" text a substring match accepts too.
    const replacement = ["new conversation"];
    await host.transform({ sessionID: "session-new" }, { system: replacement });
    expect(replacement).toEqual([
      "new conversation",
      `${HEADING}\nHerdr resource context unavailable: the shared resource query failed. This must not be treated as an empty resource branch.`,
    ]);
    expect(host.promptAsyncCalls()).toBe(0);
  });

  test("a request without a session identity retracts the earlier branch", async () => {
    const root = temporaryDir("herdr-resource-context-no-session-");
    writeFileSync(join(root, "context"), 'Resources:\n- pane "owned" [w1:p1]');
    const host = await loadTransform(root);

    const system = ["You are OpenCode."];
    await host.transform({ sessionID: "session-B" }, { system });
    // Exact, like the other projections in this file: the retraction below is
    // only meaningful if the branch it retracts was rendered whole first.
    expect(system).toEqual(["You are OpenCode.", `${HEADING}\nResources:\n- pane "owned" [w1:p1]`]);

    // sessionID is optional in the plugin API, so an absent one is a supported
    // state. Returning early would leave the previous request's branch in the
    // system prompt, presented as current.
    await host.transform({}, { system });
    expect(system).toEqual([
      "You are OpenCode.",
      `${HEADING}\nHerdr resource context unavailable: OpenCode did not expose a native session identity. This must not be treated as an empty resource branch.`,
    ]);
  });

  test("outside Herdr the plugin leaves ordinary OpenCode behavior untouched", async () => {
    const root = temporaryDir("herdr-resource-context-outside-");
    writeFileSync(join(root, "context"), 'Resources:\n- pane "must-not-appear" [w1:p1]');

    const host = await loadPlugin(root, "");

    expect(host.hooks).toEqual({});
    expect(host.promptAsyncCalls()).toBe(0);
    expect(() => readFileSync(join(root, "query-argv"), "utf8")).toThrow();
  });
});
