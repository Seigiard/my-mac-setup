import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const extensionPath =
  process.env.PI_AGENTS_LOCAL_EXTENSION_PATH ?? join(import.meta.dir, "../home/dot_pi/agent/extensions/agents-local.ts");
const {
  default: registerAgentsLocalExtension,
  inspectLocalInstructions,
  MAX_LOCAL_INSTRUCTIONS_BYTES,
} = await import(extensionPath);

const cleanupPaths: string[] = [];

async function temporaryProject(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "pi-agents-local-test-"));
  cleanupPaths.push(root);
  return root;
}

afterEach(async () => {
  for (const path of cleanupPaths.splice(0)) {
    await rm(path, { recursive: true, force: true });
  }
});

function fakePi() {
  const handlers: Record<string, Function> = {};
  const pi = {
    on: (event: string, handler: Function) => {
      handlers[event] = handler;
    },
  };
  registerAgentsLocalExtension(pi as never);
  return { handlers };
}

function fakeContext(cwd: string) {
  const notifications: Array<{ message: string; level: string }> = [];
  return {
    ctx: {
      cwd,
      hasUI: true,
      ui: {
        notify: (message: string, level: string) => notifications.push({ message, level }),
      },
    },
    notifications,
  };
}

const BASE_PROMPT = "Base prompt";

describe("Pi AGENTS.local.md extension selection", () => {
  test("loads AGENTS.local.md when only AGENTS.local.md exists", async () => {
    const root = await temporaryProject();
    await writeFile(join(root, "AGENTS.local.md"), "Use the local AGENTS file.\n");

    const selection = await inspectLocalInstructions(root);

    expect(selection.selected?.name).toBe("AGENTS.local.md");
  });

  test("prefers AGENTS.local.md when both local files resolve to different files", async () => {
    const root = await temporaryProject();
    await writeFile(join(root, "AGENTS.local.md"), "Use AGENTS.\n");
    await writeFile(join(root, "CLAUDE.local.md"), "Use CLAUDE.\n");

    const selection = await inspectLocalInstructions(root);

    expect(selection.selected?.name).toBe("AGENTS.local.md");
  });

  test("skips a broken symlink and warns once per session", async () => {
    const root = await temporaryProject();
    await symlink("missing-target.md", join(root, "AGENTS.local.md"));
    const fallbackSentinel = "SENTINEL_FALLBACK_9f1c";
    await writeFile(join(root, "CLAUDE.local.md"), `Fallback instructions ${fallbackSentinel}.\n`);
    const { handlers } = fakePi();
    const { ctx, notifications } = fakeContext(root);

    const first = await handlers.before_agent_start({ systemPrompt: BASE_PROMPT }, ctx);
    const second = await handlers.before_agent_start({ systemPrompt: BASE_PROMPT }, ctx);

    // The broken AGENTS.local.md symlink cannot supply a prompt, so the
    // extension must fall back to CLAUDE.local.md's real content on every call.
    expect(first.systemPrompt.startsWith(BASE_PROMPT)).toBe(true);
    expect(first.systemPrompt).toContain(fallbackSentinel);
    expect(second.systemPrompt.startsWith(BASE_PROMPT)).toBe(true);
    expect(second.systemPrompt).toContain(fallbackSentinel);

    expect(notifications).toHaveLength(1);
    expect(notifications[0].level).toBe("warning");
    expect(notifications[0].message).toContain("broken symlink");
  });

  test("skips a too-large file and falls back to the other local file", async () => {
    const root = await temporaryProject();
    await writeFile(join(root, "AGENTS.local.md"), "A".repeat(MAX_LOCAL_INSTRUCTIONS_BYTES + 1));
    await writeFile(join(root, "CLAUDE.local.md"), "Fallback instructions.\n");

    const selection = await inspectLocalInstructions(root);

    expect(selection.selected?.name).toBe("CLAUDE.local.md");
    expect(selection.warnings[0]).toContain("above the 51200 byte limit");
  });

  test("skips an outside-project symlink and falls back to the other local file", async () => {
    const root = await temporaryProject();
    const outsideRoot = await temporaryProject();
    const outsideInstructions = join(outsideRoot, "outside.md");
    await writeFile(outsideInstructions, "Do not load outside instructions.\n");
    await symlink(outsideInstructions, join(root, "AGENTS.local.md"));
    await writeFile(join(root, "CLAUDE.local.md"), "Fallback instructions.\n");

    const selection = await inspectLocalInstructions(root);

    expect(selection.selected?.name).toBe("CLAUDE.local.md");
    expect(selection.warnings[0]).toContain("resolves outside the project");
  });

  test("skips a directory without warning", async () => {
    const root = await temporaryProject();
    await mkdir(join(root, "AGENTS.local.md"));

    const selection = await inspectLocalInstructions(root);

    expect(selection.selected).toBeUndefined();
    expect(selection.warnings).toEqual([]);
  });
});

describe("Pi before_agent_start systemPrompt injection", () => {
  test("injects the selected AGENTS.local.md content and excludes the CLAUDE.local.md fallback", async () => {
    const root = await temporaryProject();
    const agentsSentinel = "SENTINEL_AGENTS_4c2e91";
    const claudeSentinel = "SENTINEL_CLAUDE_7a08bd";
    await writeFile(join(root, "AGENTS.local.md"), `Use the local AGENTS file. ${agentsSentinel}\n`);
    await writeFile(join(root, "CLAUDE.local.md"), `Use the local CLAUDE file. ${claudeSentinel}\n`);
    const { handlers } = fakePi();
    const { ctx } = fakeContext(root);

    const result = await handlers.before_agent_start({ systemPrompt: BASE_PROMPT }, ctx);

    expect(result.systemPrompt.startsWith(BASE_PROMPT)).toBe(true);
    expect(result.systemPrompt).toContain(agentsSentinel);
    // oracle: claudeSentinel is a fixture value this test wrote independently of the extension's source; a selection regression that injects the unselected fallback would leak it into the prompt.
    expect(result.systemPrompt).not.toContain(claudeSentinel);
  });

  test("injects CLAUDE.local.md content when it is the only local instructions file", async () => {
    const root = await temporaryProject();
    const claudeSentinel = "SENTINEL_CLAUDE_ONLY_1d5f3a";
    await writeFile(join(root, "CLAUDE.local.md"), `Use the local CLAUDE file. ${claudeSentinel}\n`);
    const { handlers } = fakePi();
    const { ctx } = fakeContext(root);

    const result = await handlers.before_agent_start({ systemPrompt: BASE_PROMPT }, ctx);

    expect(result.systemPrompt.startsWith(BASE_PROMPT)).toBe(true);
    expect(result.systemPrompt).toContain(claudeSentinel);
  });

  test("leaves the prompt untouched when no local instructions file exists", async () => {
    const root = await temporaryProject();
    const { handlers } = fakePi();
    const { ctx } = fakeContext(root);

    const result = await handlers.before_agent_start({ systemPrompt: BASE_PROMPT }, ctx);

    // No override object means the caller keeps its original systemPrompt
    // untouched; that "no-op" contract is what proves the base prompt survives.
    expect(result).toBeUndefined();
  });
});
