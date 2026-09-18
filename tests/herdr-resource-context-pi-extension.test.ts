import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const EXTENSION_PATH =
  process.env.HERDR_RESOURCE_CONTEXT_PI_EXTENSION_PATH ??
  join(import.meta.dir, "../home/dot_pi/agent/extensions/herdr-resource-context.ts");
const HEADING = "## Herdr Agent Resource Context (generated)";
const START = "<!-- herdr-resource-context:start -->";
const END = "<!-- herdr-resource-context:end -->";

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

function installQueryStub(root: string): string {
  const cli = join(root, "herdr-resource-tree");
  writeFileSync(
    cli,
    `#!/bin/sh
root=${JSON.stringify(root)}
printf '%s\n' "$@" >> ${JSON.stringify(join(root, "query-argv"))}
session="$5"
if [ -f "$root/fail-$session" ]; then
  printf 'snapshot unavailable\n' >&2
  exit 1
fi
if [ -f "$root/context-$session" ]; then
  cat "$root/context-$session"
else
  cat "$root/context"
fi
`,
  );
  chmodSync(cli, 0o755);
  return cli;
}

function context(sessionID?: string) {
  return {
    sessionManager: {
      getSessionId: () => sessionID,
    },
  };
}

async function loadExtension(root: string, herdrEnv = "1") {
  const cli = installQueryStub(root);
  const copy = join(temporaryDir("herdr-resource-context-pi-extension-"), `extension-${loadCount++}.ts`);
  cpSync(EXTENSION_PATH, copy);

  const previous = {
    HOME: process.env.HOME,
    HERDR_ENV: process.env.HERDR_ENV,
    HERDR_RESOURCE_CONTEXT_CLI: process.env.HERDR_RESOURCE_CONTEXT_CLI,
  };
  process.env.HOME = root;
  process.env.HERDR_ENV = herdrEnv;
  process.env.HERDR_RESOURCE_CONTEXT_CLI = cli;

  const handlers = new Map<string, Function>();
  let sendMessageCalls = 0;
  try {
    const { default: registerResourceContext } = await import(copy);
    registerResourceContext({
      on: (event: string, handler: Function) => handlers.set(event, handler),
      sendMessage: () => sendMessageCalls++,
    } as never);
    return { handlers, sendMessageCalls: () => sendMessageCalls };
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

function generatedBlock(context: string): string {
  return `${START}\n${HEADING}\n${context}\n${END}`;
}

describe("Pi model-request resource context", () => {
  test("a resumed session's shared branch projection reaches model input without a synthetic turn", async () => {
    const root = temporaryDir("herdr-resource-context-pi-");
    const projected = [
      'Parent agent: "agent-a"',
      'Descendant agent: "agent-c" [herdr:opencode/id/session-C]',
      "Resources:",
      '- workspace "Project" [w1] creator=herdr:pi/id/session-B',
      '    - pane "owned" [w1:pC] terminal=term-C creator=herdr:pi/id/session-B',
      "Context truncated. Full branch: `herdr-resource-tree --branch`.",
    ].join("\n");
    writeFileSync(join(root, "context-session-B"), projected);
    const host = await loadExtension(root);
    const ctx = context("session-B");

    await host.handlers.get("session_start")?.({ reason: "resume" }, ctx);
    const result = await host.handlers.get("before_agent_start")?.(
      { systemPrompt: "You are Pi.", prompt: "continue" },
      ctx,
    );

    expect(result.systemPrompt).toBe(`You are Pi.\n\n${generatedBlock(projected)}`);
    expect(readFileSync(join(root, "query-argv"), "utf8").trim().split("\n")).toEqual([
      "--context",
      "--caller-agent",
      "pi",
      "--caller-session-id",
      "session-B",
    ]);
    expect(host.sendMessageCalls()).toBe(0);
  });

  test("the same conversation refreshes in place while a new conversation gets its own identity", async () => {
    const root = temporaryDir("herdr-resource-context-pi-session-");
    writeFileSync(join(root, "context-session-B"), 'Resources:\n- pane "first" [w1:p1]');
    writeFileSync(join(root, "context-session-new"), 'Resources:\n- pane "replacement" [w1:p2]');
    const host = await loadExtension(root);
    const resumed = context("session-B");

    await host.handlers.get("session_start")?.({ reason: "resume" }, resumed);
    const first = await host.handlers.get("before_agent_start")?.(
      { systemPrompt: "Base prompt", prompt: "first" },
      resumed,
    );
    expect(first.systemPrompt).toContain('pane "first"');

    writeFileSync(join(root, "context-session-B"), 'Resources:\n- pane "refreshed" [w1:p3]');
    const refreshed = await host.handlers.get("before_agent_start")?.(
      { systemPrompt: first.systemPrompt, prompt: "next" },
      resumed,
    );
    expect(refreshed.systemPrompt).toContain('pane "refreshed"');
    expect(refreshed.systemPrompt).not.toContain('pane "first"');
    expect(refreshed.systemPrompt.split(HEADING)).toHaveLength(2);

    const replacement = context("session-new");
    await host.handlers.get("session_start")?.({ reason: "new" }, replacement);
    const replaced = await host.handlers.get("before_agent_start")?.(
      { systemPrompt: refreshed.systemPrompt, prompt: "replacement" },
      replacement,
    );
    expect(replaced.systemPrompt).toContain('pane "replacement"');
    expect(replaced.systemPrompt).not.toContain('pane "refreshed"');

    const queryArgs = readFileSync(join(root, "query-argv"), "utf8").trim().split("\n");
    expect(queryArgs.filter((argument) => argument === "session-B")).toHaveLength(2);
    expect(queryArgs.filter((argument) => argument === "session-new")).toHaveLength(1);
    expect(host.sendMessageCalls()).toBe(0);
  });

  test("empty, failed, and identity-mismatched queries remain distinct", async () => {
    const root = temporaryDir("herdr-resource-context-pi-failure-");
    writeFileSync(join(root, "context"), "");
    const host = await loadExtension(root);
    const ctx = context("session-B");
    await host.handlers.get("session_start")?.({ reason: "startup" }, ctx);
    const stale = generatedBlock('Resources:\n- pane "stale" [old]');

    const empty = await host.handlers.get("before_agent_start")?.(
      { systemPrompt: `Base prompt\n\n${stale}`, prompt: "empty" },
      ctx,
    );
    expect(empty.systemPrompt).toBe("Base prompt");

    writeFileSync(join(root, "fail-session-B"), "");
    const failed = await host.handlers.get("before_agent_start")?.(
      { systemPrompt: `Base prompt\n\n${stale}`, prompt: "failed" },
      ctx,
    );
    expect(failed.systemPrompt).toContain("Herdr resource context unavailable");
    expect(failed.systemPrompt).toContain("must not be treated as an empty resource branch");
    expect(failed.systemPrompt).not.toContain('pane "stale"');

    const mismatch = await host.handlers.get("before_agent_start")?.(
      { systemPrompt: `Base prompt\n\n${stale}`, prompt: "replacement" },
      context("session-new"),
    );
    expect(mismatch.systemPrompt).toContain("Pi session identity changed");
    expect(mismatch.systemPrompt).not.toContain('pane "stale"');

    const missing = await host.handlers.get("before_agent_start")?.(
      { systemPrompt: `Base prompt\n\n${stale}`, prompt: "missing" },
      context(),
    );
    expect(missing.systemPrompt).toContain("Pi did not expose a native session identity");
    expect(missing.systemPrompt).not.toContain('pane "stale"');

    const queryArgs = readFileSync(join(root, "query-argv"), "utf8").trim().split("\n");
    expect(queryArgs.filter((argument) => argument === "session-B")).toHaveLength(2);
    expect(host.sendMessageCalls()).toBe(0);
  });

  test("outside Herdr the extension leaves ordinary Pi behavior untouched", async () => {
    const root = temporaryDir("herdr-resource-context-pi-outside-");
    writeFileSync(join(root, "context"), 'Resources:\n- pane "must-not-appear" [w1:p1]');

    const host = await loadExtension(root, "");

    expect(host.handlers.size).toBe(0);
    expect(host.sendMessageCalls()).toBe(0);
    expect(() => readFileSync(join(root, "query-argv"), "utf8")).toThrow();
  });
});
