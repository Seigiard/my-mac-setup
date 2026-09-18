import { afterEach, describe, expect, test } from "bun:test";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const OPENCODE_LOADER =
  process.env.AGENT_INTERCOM_OPENCODE_LOADER_PATH ??
  join(import.meta.dir, "../home/private_dot_config/opencode/plugins/agent-intercom.ts");
const PI_LOADER =
  process.env.AGENT_INTERCOM_PI_LOADER_PATH ??
  join(import.meta.dir, "../home/dot_pi/agent/extensions/agent-intercom.ts");
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

async function loadModulesFromHome(
  loader: string,
  home: string,
  herdr: boolean,
  activation: Record<string, string> = {},
  count = 1,
): Promise<any[]> {
  const copy = join(temporaryDir("agent-intercom-loader-"), `loader-${loadCount++}.ts`);
  cpSync(loader, copy);
  const keys = ["HOME", "HERDR_ENV", "OPENCODE_INTERCOM_NAME", "HERDR_AGENT_INTERCOM_PI_LOAD"];
  const previous = new Map(keys.map((key) => [key, process.env[key]]));
  for (const key of keys) delete process.env[key];
  process.env.HOME = home;
  if (herdr) process.env.HERDR_ENV = "1";
  Object.assign(process.env, activation);
  try {
    const modules = [];
    for (let index = 0; index < count; index += 1) {
      modules.push(await import(`${copy}?load=${index}`));
    }
    return modules;
  } finally {
    for (const [key, value] of previous) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

async function loadFromHome(
  loader: string,
  home: string,
  herdr: boolean,
  activation: Record<string, string> = {},
): Promise<any> {
  return (await loadModulesFromHome(loader, home, herdr, activation))[0];
}

afterEach(() => {
  for (const path of temporaryPaths.splice(0)) rmSync(path, { recursive: true, force: true });
});

describe("Agent Intercom package pins", () => {
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

  test("is a no-op when the server plugin fails during initialization", async () => {
    const home = temporaryDir("agent-intercom-opencode-broken-");
    const packageDir = join(packageRoot(home), "@dataforxyz", "agent-intercom-opencode");
    mkdirSync(join(packageDir, "dist"), { recursive: true });
    await Bun.write(
      join(packageDir, "dist", "plugin.mjs"),
      "export default async () => { throw new Error('initialization failed'); };\n",
    );

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
      HERDR_AGENT_INTERCOM_PI_LOAD: String(process.pid),
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
      HERDR_AGENT_INTERCOM_PI_LOAD: String(process.pid),
    });
    const pi: Record<string, unknown> = {};
    module.default(pi);
    expect(pi).toEqual({});
  });

  test("is a no-op when the native extension fails during initialization", async () => {
    const home = temporaryDir("agent-intercom-pi-broken-");
    const packageDir = join(packageRoot(home), "@dataforxyz", "agent-intercom-pi");
    mkdirSync(packageDir, { recursive: true });
    await Bun.write(
      join(packageDir, "index.ts"),
      "export default () => { throw new Error('initialization failed'); };\n",
    );

    const module = await loadFromHome(PI_LOADER, home, true, {
      HERDR_AGENT_INTERCOM_PI_LOAD: String(process.pid),
    });
    expect(module.default({})).toBeUndefined();
  });

  test("stays active when Pi reloads extensions in the same process", async () => {
    const home = temporaryDir("agent-intercom-pi-reload-");
    const packageDir = join(packageRoot(home), "@dataforxyz", "agent-intercom-pi");
    mkdirSync(packageDir, { recursive: true });
    await Bun.write(
      join(packageDir, "index.ts"),
      "export default (pi: any) => { pi.transport = 'native'; };\n",
    );

    const modules = await loadModulesFromHome(
      PI_LOADER,
      home,
      true,
      { HERDR_AGENT_INTERCOM_PI_LOAD: String(process.pid) },
      2,
    );
    const initial: Record<string, unknown> = {};
    const reloaded: Record<string, unknown> = {};
    modules[0].default(initial);
    modules[1].default(reloaded);
    expect(initial).toEqual({ transport: "native" });
    expect(reloaded).toEqual({ transport: "native" });
  });

  test("ignores an activation marker inherited from another process", async () => {
    const home = temporaryDir("agent-intercom-pi-nested-");
    const packageDir = join(packageRoot(home), "@dataforxyz", "agent-intercom-pi");
    mkdirSync(packageDir, { recursive: true });
    await Bun.write(
      join(packageDir, "index.ts"),
      "export default (pi: any) => { pi.transport = 'native'; };\n",
    );

    const module = await loadFromHome(PI_LOADER, home, true, {
      HERDR_AGENT_INTERCOM_PI_LOAD: String(process.pid + 1),
    });
    const pi: Record<string, unknown> = {};
    module.default(pi);
    expect(pi).toEqual({});
  });
});
