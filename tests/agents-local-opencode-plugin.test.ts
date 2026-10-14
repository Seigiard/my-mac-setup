import { afterEach, describe, expect, test } from "bun:test";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { mkdir, realpath, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

// This suite is deliberately separate from tests/agent-hooks-opencode-adapter.test.ts.
// agents-local is system-prompt injection, not tool-call dispatch: it shares
// the lib root with the core for deployment reasons only, and scenario 5 below
// pins that there is no import edge between them (KTD11). Folding these cases
// into the dispatch adapter's suite would blur the boundary this unit exists
// to draw.

const PLUGIN_PATH =
  process.env.AGENTS_LOCAL_OPENCODE_PLUGIN_PATH ??
  join(import.meta.dir, "../home/private_dot_config/opencode/plugins/agents-local.ts");

const PI_EXTENSION_PATH =
  process.env.PI_AGENTS_LOCAL_EXTENSION_PATH ?? join(import.meta.dir, "../home/dot_pi/private_agent/extensions/agents-local.ts");

const CORE_DIR = process.env.AGENT_HOOKS_CORE_PATH ?? join(import.meta.dir, "../home/dot_local/lib/agent-hooks");

const shared: any = await import(join(CORE_DIR, "local-instructions.ts"));

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
// Both consumers resolve the shared module once from $HOME at module scope, so
// each load gets its own home and its own copy of the file: bun would
// otherwise hand back the cached module and every later load would silently
// reuse the first one's resolution.

async function loadUnderHome(sourcePath: string, prefix: string): Promise<any> {
  const home = temporaryDir(`${prefix}-home-`);
  mkdirSync(join(home, ".local", "lib"), { recursive: true });
  symlinkSync(CORE_DIR, join(home, ".local", "lib", "agent-hooks"));

  const copyDirectory = temporaryDir(`${prefix}-copy-`);
  const copy = join(copyDirectory, `${prefix}-${loadCount++}.ts`);
  cpSync(sourcePath, copy);

  const previousHome = process.env.HOME;
  process.env.HOME = home;

  try {
    return await import(copy);
  } finally {
    process.env.HOME = previousHome;
  }
}

function installV2PluginRuntime(directory: string): void {
  const packageDirectory = join(directory, "node_modules", "@opencode", "plugin");
  mkdirSync(packageDirectory, { recursive: true });
  writeFileSync(join(packageDirectory, "package.json"), '{"type":"module","exports":"./index.js"}\n');
  writeFileSync(join(packageDirectory, "index.js"), "export const Plugin = { define: (plugin) => plugin };\n");
}

type V2SystemPart = { type: "text"; text: string };

type V2Request = { sessionID: string; system: V2SystemPart[] };

type V2ContextHook = (request: V2Request) => Promise<void>;

type V2RequestKind = "context" | "compaction" | "generate" | "title";

type V2ContextHooks = Partial<Record<V2RequestKind, V2ContextHook>> &
  Pick<Record<V2RequestKind, V2ContextHook>, "context">;

type V2Plugin = {
  setup: (ctx: {
    session: {
      get: (input: { sessionID: string }) => Promise<{ location?: { directory?: string } }>;
      hook: (kind: string, handler: V2ContextHook) => Promise<void>;
    };
  }) => Promise<void>;
};

async function loadV2ContextHook(
  directories: Record<string, string | undefined>,
  rejectedSessionIDs: readonly string[] = [],
): Promise<V2ContextHooks> {
  const home = temporaryDir("agents-local-v2-home-");
  mkdirSync(join(home, ".local", "lib"), { recursive: true });
  symlinkSync(CORE_DIR, join(home, ".local", "lib", "agent-hooks"));

  const copyDirectory = temporaryDir("agents-local-v2-copy-");
  installV2PluginRuntime(copyDirectory);
  const copy = join(copyDirectory, `agents-local-v2-${loadCount++}.ts`);
  cpSync(PLUGIN_PATH, copy);

  const previousHome = process.env.HOME;
  process.env.HOME = home;

  try {
    // SAFETY: the fixture imports the candidate after installing its V2 Plugin.define
    // identity stub, so only the candidate's default plugin export is read here.
    const module = (await import(copy)) as { default?: V2Plugin };

    const plugin = module.default;

    if (!plugin) throw new Error("V2 plugin definition is unavailable");

    const hooks: Record<string, V2ContextHook> = {};

    await plugin.setup({
      session: {
        get: async ({ sessionID }) => {
          if (rejectedSessionIDs.includes(sessionID)) throw new Error("session lookup unavailable");

          return { location: { directory: directories[sessionID] } };
        },
        hook: async (kind, handler) => {
          hooks[kind] = handler;
        },
      },
    });

    if (!hooks.context) throw new Error("V2 context hook is unavailable");

    return hooks as V2ContextHooks;
  } finally {
    process.env.HOME = previousHome;
  }
}

type Hook = (input: { sessionID?: string }, output: { system: string[] }) => Promise<void>;

type SystemPart = { type: "text"; text: string };

async function runV2Request(
  hooks: Partial<Record<V2RequestKind, V2ContextHook>>,
  kind: V2RequestKind,
  sessionID: string,
  initialSystem: string[] = [BASE_SYSTEM],
): Promise<string[]> {
  const system = initialSystem.map((text) => ({ type: "text" as const, text }));
  await hooks[kind]?.({ sessionID, system });

  return system.map((part) => part.text);
}

async function loadV1Transform(directory: string): Promise<Hook> {
  const module: any = await loadUnderHome(PLUGIN_PATH, "agents-local-opencode-session");
  const server = module.default?.server;
  expect(server).toBeTypeOf("function");
  const hooks = (await server({ directory, worktree: directory })) ?? {};
  const transform = hooks["experimental.chat.system.transform"];
  expect(transform).toBeTypeOf("function");

  return transform;
}

async function loadV2Transform(directory: string): Promise<Hook> {
  const hooks = await loadV2ContextHook({ "session-current": directory });

  return async (input, output) => {
    const system = await runV2Request(hooks, "context", input.sessionID ?? "session-current", output.system);
    output.system.splice(0, output.system.length, ...system);
  };
}

async function loadSharedTransforms(directory: string): Promise<{ v1: Hook; v2: Hook }> {
  return { v1: await loadV1Transform(directory), v2: await loadV2Transform(directory) };
}

async function loadPiHandler(): Promise<Function> {
  const module: any = await loadUnderHome(PI_EXTENSION_PATH, "agents-local-pi");
  const handlers: Record<string, Function> = {};
  module.default({ on: (event: string, handler: Function) => (handlers[event] = handler) });
  // An extension that registered nothing hands back `undefined`, which the
  // caller would then surface as a TypeError from wherever it happened to call
  // it. Name the missing registration here instead.
  expect(handlers.before_agent_start).toBeTypeOf("function");

  return handlers.before_agent_start;
}

const BASE_SYSTEM = "You are opencode.";

const LOCAL_HEADING = "## Local Private Project Instructions";

function expectedLocalBlock(path: string, contents: string): string {
  return [
    "",
    "",
    LOCAL_HEADING,
    "",
    `Loaded from ${path}. These instructions are private and local. Follow them in addition to repository instructions.`,
    "",
    "### AGENTS.local.md",
    "",
    contents,
  ].join("\n");
}

function staleLocalBlock(marker: string): string {
  return [
    LOCAL_HEADING,
    "",
    "Loaded from /retired-worktree/AGENTS.local.md. These instructions are private and local. Follow them in addition to repository instructions.",
    "",
    "### AGENTS.local.md",
    "",
    marker,
  ].join("\n");
}

async function projectWithAgentsLocal(contents: string): Promise<string> {
  const root = temporaryDir("agents-local-project-");
  await writeFile(join(root, "AGENTS.local.md"), contents);

  return root;
}

// --- scenario 1: shared-module parity ---------------------------------------

describe("shared selection module (R7)", () => {
  test("pi and opencode emit the same literal block for the same tree", async () => {
    // #given one project tree and both consumers pointed at it
    const contents = "Shared fixture SENTINEL_PARITY_5e1a.\n";
    const root = await projectWithAgentsLocal(contents);
    const selectedRealPath = await realpath(join(root, "AGENTS.local.md"));
    const transforms = await loadSharedTransforms(root);
    const piHandler = await loadPiHandler();

    // #when each OpenCode generation and Pi inject
    const v1System = [BASE_SYSTEM];
    const v2System = [BASE_SYSTEM];
    await transforms.v1({}, { system: v1System });
    await transforms.v2({}, { system: v2System });
    const piResult = await piHandler({ systemPrompt: BASE_SYSTEM }, { cwd: root, hasUI: false });

    // #then both sides emit this exact block. Written out rather than read back
    // from the formatter: the heading is the plugin's own idempotence marker
    // (agents-local.ts reads it back), and the "Loaded from" line and the
    // `### <file name>` sub-heading are what tells a prompt reader whose
    // instructions these are. Comparing the two consumers to each other proves
    // only that they call one function, which they do by construction.
    const block = [
      "",
      "",
      "## Local Private Project Instructions",
      "",
      `Loaded from ${selectedRealPath}. These instructions are private and local. Follow them in addition to repository instructions.`,
      "",
      "### AGENTS.local.md",
      "",
      contents,
    ].join("\n");

    expect([v1System, v2System]).toEqual([
      [BASE_SYSTEM, block],
      [BASE_SYSTEM, block],
    ]);
    expect(piResult.systemPrompt).toBe(BASE_SYSTEM + block);
  });
});

describe("session-local model context", () => {
  test("all native V2 request kinds inject only their own worktree instructions", async () => {
    // #given two independent session worktrees with distinct local instructions
    const rootA = await projectWithAgentsLocal("Worktree A LOCAL_A_473.\n");
    const rootB = await projectWithAgentsLocal("Worktree B LOCAL_B_473.\n");
    const rootAInstructions = await realpath(join(rootA, "AGENTS.local.md"));
    const rootBInstructions = await realpath(join(rootB, "AGENTS.local.md"));
    const hooks = await loadV2ContextHook({ "session-A": rootA, "session-B": rootB });
    const expectedA = expectedLocalBlock(rootAInstructions, "Worktree A LOCAL_A_473.\n");
    const expectedB = expectedLocalBlock(rootBInstructions, "Worktree B LOCAL_B_473.\n");

    // #when both sessions construct every native kind through the same plugin instance
    const actual = await Promise.all([
      runV2Request(hooks, "context", "session-A"),
      runV2Request(hooks, "context", "session-B"),
      runV2Request(hooks, "compaction", "session-B"),
      runV2Request(hooks, "generate", "session-B"),
      runV2Request(hooks, "title", "session-B"),
    ]);

    // #then each model request carries the context selected from its own worktree
    expect(actual).toEqual([
      [BASE_SYSTEM, expectedA],
      [BASE_SYSTEM, expectedB],
      [BASE_SYSTEM, expectedB],
      [BASE_SYSTEM, expectedB],
      [BASE_SYSTEM, expectedB],
    ]);
  });

});

// --- scenario 2: the safety checks reach opencode ----------------------------

describe("selection safety in opencode (R7)", () => {
  test("a symlink escaping the project root is skipped and the in-project file wins", async () => {
    // #given AGENTS.local.md pointing outside the project, CLAUDE.local.md inside it
    const root = temporaryDir("agents-local-escape-");
    const outside = temporaryDir("agents-local-outside-");
    const outsideFile = join(outside, "outside.md");
    await writeFile(outsideFile, "OUTSIDE_SENTINEL_c40b must never be injected.\n");
    await symlink(outsideFile, join(root, "AGENTS.local.md"));
    await writeFile(join(root, "CLAUDE.local.md"), "In-project fallback INSIDE_SENTINEL_9d3f.\n");
    const transforms = await loadSharedTransforms(root);

    // #when the transform runs
    const v1System = [BASE_SYSTEM];
    const v2System = [BASE_SYSTEM];
    await transforms.v1({}, { system: v1System });
    await transforms.v2({}, { system: v2System });

    // #then only the in-project file reaches the prompt
    expect([v1System, v2System]).toEqual([
      [BASE_SYSTEM, expect.stringContaining("INSIDE_SENTINEL_9d3f")],
      [BASE_SYSTEM, expect.stringContaining("INSIDE_SENTINEL_9d3f")],
    ]);
    // oracle: this string lives in a file outside the project root, written
    // independently of any source in this patch; a regressed escape check
    // leaks content the project does not own into every request's prompt.
    expect([...v1System, ...v2System].join("\n")).not.toContain("OUTSIDE_SENTINEL_c40b");
  });

  test("a file over the size cap is skipped and the under-cap control is injected", async () => {
    // #given an over-cap AGENTS.local.md next to an under-cap CLAUDE.local.md
    const root = temporaryDir("agents-local-cap-");
    await writeFile(join(root, "AGENTS.local.md"), "A".repeat(shared.MAX_LOCAL_INSTRUCTIONS_BYTES + 1));
    await writeFile(join(root, "CLAUDE.local.md"), "Under the cap UNDERCAP_SENTINEL_71ee.\n");
    const transforms = await loadSharedTransforms(root);

    // #when the transform runs
    const v1System = [BASE_SYSTEM];
    const v2System = [BASE_SYSTEM];
    await transforms.v1({}, { system: v1System });
    await transforms.v2({}, { system: v2System });

    // #then the oversized file is not what was injected
    expect([v1System, v2System]).toEqual([
      [BASE_SYSTEM, expect.stringContaining("UNDERCAP_SENTINEL_71ee")],
      [BASE_SYSTEM, expect.stringContaining("UNDERCAP_SENTINEL_71ee")],
    ]);
    // oracle: the run of "A" is the over-cap fixture's own bytes, sized from
    // the cap the shared module publishes; a regressed cap check pushes a
    // 50 KiB+ file into every request's system prompt.
    expect([...v1System, ...v2System].join("\n")).not.toContain("AAAAAAAAAA");
  });

  test("a directory named AGENTS.local.md leaves the prompt alone", async () => {
    // #given a directory where the instructions file would be
    const root = temporaryDir("agents-local-dir-");
    await mkdir(join(root, "AGENTS.local.md"));
    const transforms = await loadSharedTransforms(root);

    // #when the transform runs
    const v1System = [BASE_SYSTEM];
    const v2System = [BASE_SYSTEM];
    await transforms.v1({}, { system: v1System });
    await transforms.v2({}, { system: v2System });

    // #then nothing was appended
    expect([v1System, v2System]).toEqual([[BASE_SYSTEM], [BASE_SYSTEM]]);
  });
});

// --- scenario 3: idempotence (KTD11) ----------------------------------------

describe("heading-guarded idempotence (KTD11)", () => {
  test("a second call over an already-injected array appends nothing", async () => {
    // #given a system array the transform has already injected into
    const root = await projectWithAgentsLocal("Injected once IDEMPOTENT_SENTINEL_2b7c.\n");
    const transforms = await loadSharedTransforms(root);
    const v1System = [BASE_SYSTEM];
    const v2System = [BASE_SYSTEM];
    await transforms.v1({}, { system: v1System });
    await transforms.v2({}, { system: v2System });
    const afterFirst = [v1System, v2System].map((system) => [...system]);

    // #when the same array is transformed again
    await transforms.v1({}, { system: v1System });
    await transforms.v2({}, { system: v2System });

    // #then the array is unchanged: one heading, one copy of the content
    expect([v1System, v2System]).toEqual(afterFirst);
    expect([v1System, v2System].flat().join("\n").split("IDEMPOTENT_SENTINEL_2b7c")).toHaveLength(3);
  });

  test("a V1 array carrying a stale generated heading is replaced", async () => {
    // #given an array carrying generated instructions from an earlier request
    const root = await projectWithAgentsLocal("Would be injected NEW_SENTINEL_8f10.\n");
    const selectedRealPath = await realpath(join(root, "AGENTS.local.md"));
    const transform = await loadV1Transform(root);

    const preInjected = [
      "",
      "",
      "## Local Private Project Instructions",
      "",
      `Loaded from ${selectedRealPath}. These instructions are private and local. Follow them in addition to repository instructions.`,
      "",
      "### AGENTS.local.md",
      "",
      "Earlier generated LOCAL_INSTRUCTIONS_OLD_473.\n",
    ].join("\n");

    const unrelated = "Keep this ordinary reference: ## Local Private Project Instructions.";
    const system = [BASE_SYSTEM, unrelated, preInjected];

    // #when the transform runs
    await transform({}, { system });

    // #then the current generated block replaces the stale one
    const expected = [
      BASE_SYSTEM,
      unrelated,
      [
        "",
        "",
        "## Local Private Project Instructions",
        "",
        `Loaded from ${selectedRealPath}. These instructions are private and local. Follow them in addition to repository instructions.`,
        "",
        "### AGENTS.local.md",
        "",
        "Would be injected NEW_SENTINEL_8f10.\n",
      ].join("\n"),
    ];

    expect(system).toEqual(expected);
  });
});

describe("V2 local-instruction refresh", () => {
  test("replaces duplicate generated blocks while preserving ordinary text that mentions the heading", async () => {
    // #given a V2 request preloaded with stale generated entries and unrelated text
    const root = await projectWithAgentsLocal("CURRENT_LOCAL_A_473\n");
    const selectedPath = await realpath(join(root, "AGENTS.local.md"));
    const hooks = await loadV2ContextHook({ "session-a": root });

    const ordinary = `A prose note mentions ${LOCAL_HEADING} but is not a generated local block.`;

    const system: V2SystemPart[] = [
      { type: "text", text: BASE_SYSTEM },
      { type: "text", text: staleLocalBlock("STALE_LOCAL_A_473") },
      { type: "text", text: staleLocalBlock("DUPLICATE_LOCAL_A_473") },
      { type: "text", text: ordinary },
    ];

    // #when OpenCode prepares the model request for the current session
    await hooks.context({ sessionID: "session-a", system });

    // #then exactly the current generated block remains and the ordinary part survives
    expect(system).toEqual([
      { type: "text", text: BASE_SYSTEM },
      { type: "text", text: ordinary },
      { type: "text", text: expectedLocalBlock(selectedPath, "CURRENT_LOCAL_A_473\n") },
    ]);
  });

  test("refreshes a generated local block when the selected file changes", async () => {
    // #given a session with a previously generated local block
    const root = await projectWithAgentsLocal("INITIAL_LOCAL_A_473\n");
    const selectedPath = await realpath(join(root, "AGENTS.local.md"));
    const hooks = await loadV2ContextHook({ "session-a": root });

    const system: V2SystemPart[] = [
      { type: "text", text: BASE_SYSTEM },
      { type: "text", text: expectedLocalBlock(selectedPath, "INITIAL_LOCAL_A_473\n") },
    ];

    await writeFile(join(root, "AGENTS.local.md"), "REFRESHED_LOCAL_A_473\n");

    // #when the same session prepares its next request
    await hooks.context({ sessionID: "session-a", system });

    // #then the request carries the changed content and not the old block
    expect(system).toEqual([
      { type: "text", text: BASE_SYSTEM },
      { type: "text", text: expectedLocalBlock(selectedPath, "REFRESHED_LOCAL_A_473\n") },
    ]);
  });

  test("replaces the previous session's generated block with its own worktree instructions", async () => {
    // #given a request carrying session A's generated block before session B is selected
    const rootA = await projectWithAgentsLocal("LOCAL_FOR_SESSION_A_473\n");
    const rootB = await projectWithAgentsLocal("LOCAL_FOR_SESSION_B_473\n");
    const selectedPathB = await realpath(join(rootB, "AGENTS.local.md"));

    const hooks = await loadV2ContextHook({ "session-a": rootA, "session-b": rootB });

    const system: V2SystemPart[] = [
      { type: "text", text: BASE_SYSTEM },
      { type: "text", text: expectedLocalBlock(await realpath(join(rootA, "AGENTS.local.md")), "LOCAL_FOR_SESSION_A_473\n") },
    ];

    // #when OpenCode prepares a request for session B
    await hooks.context({ sessionID: "session-b", system });

    // #then only B's local instructions reach the model input
    expect(system).toEqual([
      { type: "text", text: BASE_SYSTEM },
      { type: "text", text: expectedLocalBlock(selectedPathB, "LOCAL_FOR_SESSION_B_473\n") },
    ]);
  });

  test("removes stale generated local blocks when session lookup rejects", async () => {
    // #given an ordinary system part and stale generated instructions from another project
    const hooks = await loadV2ContextHook({}, ["session-unavailable"]);
    const ordinary = "Preserve this ordinary instruction after a lookup failure.";
    const system: V2SystemPart[] = [
      { type: "text", text: BASE_SYSTEM },
      { type: "text", text: ordinary },
      { type: "text", text: staleLocalBlock("STALE_LOOKUP_FAILURE_405") },
    ];

    // #when OpenCode cannot resolve the session for a new model request
    await hooks.context({ sessionID: "session-unavailable", system });

    // #then only the stale generated block is removed
    expect(system).toEqual([
      { type: "text", text: BASE_SYSTEM },
      { type: "text", text: ordinary },
    ]);
  });

  test("removes stale generated local blocks when session has no directory", async () => {
    // #given an ordinary system part and stale generated instructions from another project
    const hooks = await loadV2ContextHook({ "session-without-directory": undefined });
    const ordinary = "Preserve this ordinary instruction without a session directory.";
    const system: V2SystemPart[] = [
      { type: "text", text: BASE_SYSTEM },
      { type: "text", text: ordinary },
      { type: "text", text: staleLocalBlock("STALE_MISSING_DIRECTORY_405") },
    ];

    // #when OpenCode resolves the session but it has no directory
    await hooks.context({ sessionID: "session-without-directory", system });

    // #then only the stale generated block is removed
    expect(system).toEqual([
      { type: "text", text: BASE_SYSTEM },
      { type: "text", text: ordinary },
    ]);
  });

  test("removes generated local blocks when the current session has no local selection", async () => {
    // #given a request with a generated block and a session directory without AGENTS.local.md
    const root = await projectWithAgentsLocal("LOCAL_TO_REMOVE_473\n");
    const emptyRoot = temporaryDir("agents-local-v2-empty-");

    const hooks = await loadV2ContextHook({ "session-a": root, "session-empty": emptyRoot });

    const system: V2SystemPart[] = [
      { type: "text", text: BASE_SYSTEM },
      { type: "text", text: expectedLocalBlock(await realpath(join(root, "AGENTS.local.md")), "LOCAL_TO_REMOVE_473\n") },
    ];

    // #when OpenCode prepares a request for the empty selection
    await hooks.context({ sessionID: "session-empty", system });

    // #then no generated local entry remains
    expect(system).toEqual([{ type: "text", text: BASE_SYSTEM }]);
  });
});

// --- scenario 4: nothing to inject ------------------------------------------

describe("no local instructions present", () => {
  test("the system array is untouched", async () => {
    // #given a project with neither local instructions file
    const root = temporaryDir("agents-local-empty-");
    await writeFile(join(root, "AGENTS.md"), "Repository instructions, not local ones.\n");
    const transforms = await loadSharedTransforms(root);

    // #when the transform runs
    const unrelated = "Document ## Local Private Project Instructions without generating it.";
    const v1System = [BASE_SYSTEM, "second entry", unrelated];
    const v2System = [BASE_SYSTEM, "second entry", unrelated];
    await transforms.v1({}, { system: v1System });
    await transforms.v2({}, { system: v2System });

    // #then nothing changed
    expect([v1System, v2System]).toEqual([
      [BASE_SYSTEM, "second entry", unrelated],
      [BASE_SYSTEM, "second entry", unrelated],
    ]);
  });
});

// --- scenario 5: the KTD11 boundary -----------------------------------------
//
// local-instructions shares the lib root with the dispatch core for deployment
// reasons only. An import edge in either direction would drag the core's
// pure-and-synchronous policy invariant onto a module that reads the
// filesystem, or drag filesystem I/O into the tool-call path.

const LOCAL_INSTRUCTIONS_FILE = "local-instructions.ts";

function importSpecifiers(source: string): string[] {
  const specifiers: string[] = [];
  const pattern = /(?:\bfrom\s*|\bimport\s*\(\s*)["']([^"']+)["']/g;

  for (const match of source.matchAll(pattern)) specifiers.push(match[1]);

  return specifiers;
}

function typescriptFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true, recursive: true })
    .filter((entry: any) => entry.isFile() && entry.name.endsWith(".ts"))
    .map((entry: any) => join(entry.parentPath ?? entry.path ?? dir, entry.name));
}

/** Core files that name the shared module — the core-depends-on-it direction. */
function coreFilesReachingLocalInstructions(dir: string): string[] {
  return typescriptFiles(dir)
    .filter((path) => !path.endsWith(LOCAL_INSTRUCTIONS_FILE))
    .filter((path) => importSpecifiers(readFileSync(path, "utf8")).some((s) => s.includes("local-instructions")));
}

/** Non-builtin imports of the shared module — the it-depends-on-core direction. */
function localInstructionsNonBuiltinImports(dir: string): string[] {
  return importSpecifiers(readFileSync(join(dir, LOCAL_INSTRUCTIONS_FILE), "utf8")).filter(
    (specifier) => !specifier.startsWith("node:"),
  );
}

describe("no import edge to the dispatch core (KTD11)", () => {
  test("the scan detects an edge in either direction", () => {
    // #given a fake lib root where both edges exist
    const dir = temporaryDir("agents-local-edge-");
    writeFileSync(join(dir, LOCAL_INSTRUCTIONS_FILE), 'import { dispatch } from "./index.ts";\n');
    writeFileSync(join(dir, "registry.ts"), 'import { x } from "./local-instructions.ts";\n');
    writeFileSync(join(dir, "clean.ts"), 'import { join } from "node:path";\n');

    // #when both directions are scanned
    // #then each reports exactly its offender
    expect(coreFilesReachingLocalInstructions(dir).map((path) => path.endsWith("registry.ts"))).toEqual([true]);
    expect(localInstructionsNonBuiltinImports(dir)).toEqual(["./index.ts"]);
  });

  test("the shipped core and shared module import nothing from each other", () => {
    // #given the deployed lib root
    expect(typescriptFiles(CORE_DIR).length).toBeGreaterThan(1);

    // #when both directions are scanned
    // #then neither direction has an edge
    expect(coreFilesReachingLocalInstructions(CORE_DIR)).toEqual([]);
    expect(localInstructionsNonBuiltinImports(CORE_DIR)).toEqual([]);
  });
});
