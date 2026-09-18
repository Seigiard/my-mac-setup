import { afterEach, describe, expect, test } from "bun:test";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const OPENCODE_LOADER = join(
  import.meta.dir,
  "../home/private_dot_config/opencode/plugins/agent-intercom.ts",
);
const PI_LOADER = join(import.meta.dir, "../home/dot_pi/agent/extensions/agent-intercom.ts");
const PACKAGE_MANIFEST = join(
  import.meta.dir,
  "../home/dot_local/share/agent-intercom/package.json",
);
const PACKAGE_LOCK = join(
  import.meta.dir,
  "../home/dot_local/share/agent-intercom/package-lock.json",
);
const temporaryPaths: string[] = [];
let loadCount = 0;

function temporaryDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  temporaryPaths.push(dir);
  return dir;
}

function packageRoot(home: string): string {
  return join(home, ".local", "share", "agent-intercom", "node_modules");
}

async function loadFromHome(
  loader: string,
  home: string,
  herdr: boolean,
  activation: Record<string, string> = {},
): Promise<any> {
  const copy = join(temporaryDir("agent-intercom-loader-"), `loader-${loadCount++}.ts`);
  cpSync(loader, copy);
  const keys = ["HOME", "HERDR_ENV", "OPENCODE_INTERCOM_NAME", "HERDR_AGENT_INTERCOM_PI_LOAD"];
  const previous = new Map(keys.map((key) => [key, process.env[key]]));
  for (const key of keys) delete process.env[key];
  process.env.HOME = home;
  if (herdr) process.env.HERDR_ENV = "1";
  Object.assign(process.env, activation);
  try {
    return await import(copy);
  } finally {
    for (const [key, value] of previous) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

afterEach(() => {
  for (const path of temporaryPaths.splice(0)) rmSync(path, { recursive: true, force: true });
});

describe("Agent Intercom package pins", () => {
  test("the managed package set names every tested revision exactly", () => {
    const manifest = JSON.parse(readFileSync(PACKAGE_MANIFEST, "utf8"));
    expect(manifest.dependencies).toEqual({
      "@dataforxyz/agent-intercom-core":
        "git+https://github.com/dataforxyz/agent-intercom-core.git#8316cbab548f422ad11c78ed887fabeef94817c1",
      "@dataforxyz/agent-intercom-claude":
        "git+https://github.com/dataforxyz/agent-intercom-claude.git#7de76e5d4f6461b007b19dfc5dbcf11928868adc",
      "@dataforxyz/agent-intercom-opencode":
        "git+https://github.com/dataforxyz/agent-intercom-opencode.git#91ce62f03f14b89ea11fc39eedf7d44bca808cf4",
      "@dataforxyz/agent-intercom-pi":
        "git+https://github.com/dataforxyz/agent-intercom-pi.git#0fffed27d15055b866fe4e52803be6adcd363051",
    });
  });

  test("the lock resolves every git dependency over portable HTTPS URLs", () => {
    const lock = JSON.parse(readFileSync(PACKAGE_LOCK, "utf8"));
    const packages = lock.packages as Record<string, { resolved?: string }>;
    for (const name of [
      "agent-intercom-core",
      "agent-intercom-claude",
      "agent-intercom-opencode",
      "agent-intercom-pi",
    ]) {
      const entry = packages[`node_modules/@dataforxyz/${name}`];
      expect(entry.resolved).toStartWith(`git+https://github.com/dataforxyz/${name}.git#`);
    }
  });

  test("every registry artifact has a recorded integrity hash", () => {
    const lock = JSON.parse(readFileSync(PACKAGE_LOCK, "utf8"));
    const packages = Object.entries(lock.packages) as Array<
      [string, { resolved?: string; integrity?: string }]
    >;
    const missing = packages
      .filter(([, entry]) => entry.resolved?.startsWith("https://registry.npmjs.org/"))
      .filter(([, entry]) => !entry.integrity)
      .map(([path]) => path);
    expect(missing).toEqual([]);
  });
});

describe("OpenCode Agent Intercom loader", () => {
  test("loads the server plugin entrypoint without touching root or TUI modules", async () => {
    const home = temporaryDir("agent-intercom-opencode-home-");
    const packageDir = join(packageRoot(home), "@dataforxyz", "agent-intercom-opencode");
    mkdirSync(join(packageDir, "dist"), { recursive: true });
    await Bun.write(
      join(packageDir, "dist", "plugin.mjs"),
      "export default async () => ({ transport: 'server', name: process.env.OPENCODE_INTERCOM_NAME });\n",
    );
    await Bun.write(join(packageDir, "dist", "index.mjs"), "throw new Error('root loaded');\n");
    await Bun.write(join(packageDir, "dist", "tui.mjs"), "throw new Error('tui loaded');\n");

    const module = await loadFromHome(OPENCODE_LOADER, home, true, {
      OPENCODE_INTERCOM_NAME: "ochre-okapi",
    });
    expect(Object.keys(module)).toEqual(["AgentIntercomPlugin"]);
    expect(await module.AgentIntercomPlugin({})).toEqual({
      transport: "server",
      name: "ochre-okapi",
    });
    expect(process.env.OPENCODE_INTERCOM_NAME).toBeUndefined();
  });

  test("is a no-op outside Herdr without importing the package", async () => {
    const home = temporaryDir("agent-intercom-opencode-missing-");
    const module = await loadFromHome(OPENCODE_LOADER, home, false);
    expect(await module.AgentIntercomPlugin({})).toEqual({});
  });

  test("is a no-op inside Herdr without a launcher name", async () => {
    const home = temporaryDir("agent-intercom-opencode-unmarked-herdr-");
    const module = await loadFromHome(OPENCODE_LOADER, home, true);
    expect(await module.AgentIntercomPlugin({})).toEqual({});
  });

  test("is a no-op inside Herdr when the managed package is absent", async () => {
    const home = temporaryDir("agent-intercom-opencode-missing-herdr-");
    const module = await loadFromHome(OPENCODE_LOADER, home, true, {
      OPENCODE_INTERCOM_NAME: "ochre-okapi",
    });
    expect(await module.AgentIntercomPlugin({})).toEqual({});
  });
});

describe("Pi Agent Intercom loader", () => {
  test("loads and delegates to the native Pi extension", async () => {
    const home = temporaryDir("agent-intercom-pi-home-");
    const packageDir = join(packageRoot(home), "@dataforxyz", "agent-intercom-pi");
    mkdirSync(packageDir, { recursive: true });
    await Bun.write(
      join(packageDir, "index.ts"),
      "export default (pi: any) => { pi.transport = 'native'; };\n",
    );

    const module = await loadFromHome(PI_LOADER, home, true, {
      HERDR_AGENT_INTERCOM_PI_LOAD: "1",
    });
    const pi: Record<string, unknown> = {};
    module.default(pi);
    expect(pi).toEqual({ transport: "native" });
  });

  test("is a no-op outside Herdr without importing the package", async () => {
    const home = temporaryDir("agent-intercom-pi-missing-");
    const module = await loadFromHome(PI_LOADER, home, false);
    const pi: Record<string, unknown> = {};
    module.default(pi);
    expect(pi).toEqual({});
  });

  test("is a no-op inside Herdr without a one-shot launcher marker", async () => {
    const home = temporaryDir("agent-intercom-pi-unmarked-herdr-");
    const module = await loadFromHome(PI_LOADER, home, true);
    const pi: Record<string, unknown> = {};
    module.default(pi);
    expect(pi).toEqual({});
  });

  test("is a no-op inside Herdr when the managed package is absent", async () => {
    const home = temporaryDir("agent-intercom-pi-missing-herdr-");
    const module = await loadFromHome(PI_LOADER, home, true, {
      HERDR_AGENT_INTERCOM_PI_LOAD: "1",
    });
    const pi: Record<string, unknown> = {};
    module.default(pi);
    expect(pi).toEqual({});
  });
});
