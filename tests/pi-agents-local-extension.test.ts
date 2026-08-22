import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const extensionPath =
  process.env.PI_AGENTS_LOCAL_EXTENSION_PATH ?? join(import.meta.dir, "../home/dot_pi/agent/extensions/agents-local.ts");
const {
  default: registerAgentsLocalExtension,
  formatLocalInstructions,
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

describe("Pi AGENTS.local.md extension selection", () => {
  test("loads AGENTS.local.md when only AGENTS.local.md exists", async () => {
    const root = await temporaryProject();
    await writeFile(join(root, "AGENTS.local.md"), "Use the local AGENTS file.\n");

    const selection = await inspectLocalInstructions(root);

    expect(selection.selected?.name).toBe("AGENTS.local.md");
    expect(selection.diagnostics.map((diagnostic) => [diagnostic.name, diagnostic.status])).toEqual([
      ["AGENTS.local.md", "selected"],
      ["CLAUDE.local.md", "missing"],
    ]);
  });

  test("prefers AGENTS.local.md when both local files resolve to different files", async () => {
    const root = await temporaryProject();
    await writeFile(join(root, "AGENTS.local.md"), "Use AGENTS.\n");
    await writeFile(join(root, "CLAUDE.local.md"), "Use CLAUDE.\n");

    const selection = await inspectLocalInstructions(root);

    expect(selection.selected?.name).toBe("AGENTS.local.md");
    expect(selection.diagnostics.map((diagnostic) => [diagnostic.name, diagnostic.status])).toEqual([
      ["AGENTS.local.md", "selected"],
      ["CLAUDE.local.md", "skipped-preferred-agents"],
    ]);
  });

  test("skips a broken symlink and warns once per session", async () => {
    const root = await temporaryProject();
    await symlink("missing-target.md", join(root, "AGENTS.local.md"));
    await writeFile(join(root, "CLAUDE.local.md"), "Fallback instructions.\n");
    const { handlers } = fakePi();
    const { ctx, notifications } = fakeContext(root);

    await handlers.before_agent_start({ systemPrompt: "Base prompt" }, ctx);
    await handlers.before_agent_start({ systemPrompt: "Base prompt" }, ctx);

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
    expect(selection.diagnostics.map((diagnostic) => [diagnostic.name, diagnostic.status])).toEqual([
      ["AGENTS.local.md", "skipped-too-large"],
      ["CLAUDE.local.md", "selected"],
    ]);
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
    expect(selection.diagnostics.map((diagnostic) => [diagnostic.name, diagnostic.status])).toEqual([
      ["AGENTS.local.md", "skipped-outside-project"],
      ["CLAUDE.local.md", "selected"],
    ]);
    expect(selection.warnings[0]).toContain("resolves outside the project");
  });

  test("skips a directory without warning", async () => {
    const root = await temporaryProject();
    await mkdir(join(root, "AGENTS.local.md"));

    const selection = await inspectLocalInstructions(root);

    expect(selection.selected).toBeUndefined();
    expect(selection.warnings).toEqual([]);
    expect(selection.diagnostics[0].status).toBe("skipped-not-file");
  });
});

describe("Pi AGENTS.local.md extension hooks", () => {
  test("appends one local instruction block before the agent starts", async () => {
    const root = await temporaryProject();
    await writeFile(join(root, "AGENTS.local.md"), "Use only AGENTS.\n");
    await writeFile(join(root, "CLAUDE.local.md"), "Do not load this file.\n");
    const { handlers } = fakePi();
    const { ctx } = fakeContext(root);

    const result = await handlers.before_agent_start({ systemPrompt: "Base prompt" }, ctx);

    expect(result.systemPrompt).toStartWith("Base prompt");
    expect(result.systemPrompt).toContain("## Local Private Project Instructions");
    expect(result.systemPrompt).toContain("Use only AGENTS.");
    expect(result.systemPrompt).not.toContain("Do not load this file.");
  });

  test("formatLocalInstructions names the real loaded path", async () => {
    const root = await temporaryProject();
    await writeFile(join(root, "AGENTS.local.md"), "Use formatted instructions.\n");
    const selection = await inspectLocalInstructions(root);
    const content = await readFile(selection.selected!.realPath, "utf8");

    const promptBlock = formatLocalInstructions(selection.selected!, content);

    expect(promptBlock).toContain(`Loaded from ${selection.selected!.realPath}`);
    expect(promptBlock).toContain("Use formatted instructions.");
  });
});
