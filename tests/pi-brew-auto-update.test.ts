import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import type {
  BrewAutoUpdateDependencies,
  UpdateUi,
} from "../home/dot_pi/agent/extensions/brew-auto-update/index.ts";

const sourceRoot = process.env.SOURCE_ROOT ?? join(import.meta.dir, "../home");
const { default: registerBrewAutoUpdater, runBrewAutoUpdate } = await import(
  join(sourceRoot, "dot_pi/agent/extensions/brew-auto-update/index.ts"),
);

const cleanupPaths: string[] = [];

async function temporaryLockPath(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "pi-brew-auto-update-test-"));
  cleanupPaths.push(root);
  return join(root, "state", "pi", "brew-auto-update.lock");
}

afterEach(async () => {
  for (const path of cleanupPaths.splice(0)) {
    await rm(path, { recursive: true, force: true });
  }
});

function fakeUi() {
  const statuses: Array<string | undefined> = [];
  const notifications: Array<{ message: string; level: string }> = [];
  const ui: UpdateUi = {
    setStatus: (_id, value) => statuses.push(value),
    notify: (message, level) => notifications.push({ message, level }),
  };
  return { ui, statuses, notifications };
}

async function dependencies(
  overrides: Partial<BrewAutoUpdateDependencies> = {},
): Promise<{ deps: BrewAutoUpdateDependencies; calls: Array<[string, string[]]> }> {
  const calls: Array<[string, string[]]> = [];
  const deps: BrewAutoUpdateDependencies = {
    exec: async (command, args) => {
      calls.push([command, args]);
      return { code: 0, stdout: "", stderr: "", killed: false };
    },
    env: {},
    lockPath: await temporaryLockPath(),
    now: () => 1_000_000,
    pid: 4242,
    processAlive: () => true,
    token: "test-owner",
    timeoutMs: 300_000,
    staleLockMs: 1_200_000,
    ...overrides,
  };
  return { deps, calls };
}

describe("brew auto update sequence", () => {
  test("does not notify when successful commands install no updates", async () => {
    const { deps, calls } = await dependencies({
      exec: async (command, args) => {
        calls.push([command, args]);
        return {
          code: 0,
          stdout: command === "pi" ? "Updated packages\n" : "",
          stderr:
            command === "brew" && args[0] === "upgrade"
              ? "Warning: pi-coding-agent 0.84.2 already installed\n"
              : "",
          killed: false,
        };
      },
    });
    const { ui, statuses, notifications } = fakeUi();

    const result = await runBrewAutoUpdate("manual", ui, deps);

    expect(result.status).toBe("complete");
    expect(calls).toEqual([
      ["brew", ["update"]],
      ["brew", ["upgrade", "pi-coding-agent"]],
      ["pi", ["update", "--extensions"]],
    ]);
    expect(statuses).toEqual([]);
    expect(notifications).toEqual([]);
  });

  test.each([
    {
      label: "Pi",
      command: "brew",
      args: ["upgrade", "pi-coding-agent"],
      stdout: "==> Upgrading pi-coding-agent\n  0.84.1 -> 0.84.2\n",
      message: "Pi updated. Restart Pi to use the new version.",
    },
    {
      label: "extensions",
      command: "pi",
      args: ["update", "--extensions"],
      stdout: "Updating npm:example-extension...\nUpdated packages\n",
      message: "Pi extensions updated. Restart Pi to use them.",
    },
  ])("shows one specific notification when $label changed", async (updated) => {
    const { deps, calls } = await dependencies({
      exec: async (command, args) => {
        calls.push([command, args]);
        return {
          code: 0,
          stdout:
            command === updated.command && Bun.deepEquals(args, updated.args) ? updated.stdout : "",
          stderr: "",
          killed: false,
        };
      },
    });
    const { ui, statuses, notifications } = fakeUi();

    const result = await runBrewAutoUpdate("manual", ui, deps);

    expect(result.status).toBe("complete");
    expect(statuses).toEqual([]);
    expect(notifications).toEqual([{ message: updated.message, level: "info" }]);
  });

  test("combines Pi and extension updates into one notification", async () => {
    const { deps } = await dependencies({
      exec: async (command, args) => ({
        code: 0,
        stdout:
          command === "brew" && args[0] === "upgrade"
            ? "==> Upgrading pi-coding-agent\n  0.84.1 -> 0.84.2\n"
            : command === "pi"
              ? "Updating npm:example-extension...\nUpdated packages\n"
              : "",
        stderr: "",
        killed: false,
      }),
    });
    const { ui, statuses, notifications } = fakeUi();

    await runBrewAutoUpdate("manual", ui, deps);

    expect(statuses).toEqual([]);
    expect(notifications).toEqual([
      {
        message: "Pi and its extensions updated. Restart Pi to use them.",
        level: "info",
      },
    ]);
  });

  test("skips all network work when PI_OFFLINE is set", async () => {
    const { deps, calls } = await dependencies({ env: { PI_OFFLINE: "1" } });
    const { ui, statuses } = fakeUi();

    const result = await runBrewAutoUpdate("manual", ui, deps);

    expect(result.status).toBe("skipped");
    expect(calls).toEqual([]);
    expect(statuses).toEqual([]);
  });

  test("disables startup only when PI_BREW_AUTO_UPDATE is zero", async () => {
    const startup = await dependencies({ env: { PI_BREW_AUTO_UPDATE: "0" } });
    const manual = await dependencies({ env: { PI_BREW_AUTO_UPDATE: "0" } });

    expect((await runBrewAutoUpdate("startup", fakeUi().ui, startup.deps)).status).toBe("skipped");
    expect(startup.calls).toEqual([]);
    expect((await runBrewAutoUpdate("manual", fakeUi().ui, manual.deps)).status).toBe("complete");
    expect(manual.calls).toHaveLength(3);
  });

  test("stops after a timed-out command and reports the failure", async () => {
    const { deps, calls } = await dependencies({
      exec: async (command, args) => {
        calls.push([command, args]);
        return { code: null, stdout: "", stderr: "", killed: true };
      },
    });
    const { ui, statuses, notifications } = fakeUi();

    const result = await runBrewAutoUpdate("manual", ui, deps);

    expect(result.status).toBe("failed");
    expect(calls).toHaveLength(1);
    expect(statuses).toEqual([]);
    expect(notifications).toEqual([]);
  });

  test("stops on command failure without aborting the caller", async () => {
    const { deps, calls } = await dependencies({
      exec: async (command, args) => {
        calls.push([command, args]);
        return { code: 7, stdout: "", stderr: "network failed", killed: false };
      },
    });
    const { ui, notifications } = fakeUi();

    await expect(runBrewAutoUpdate("manual", ui, deps)).resolves.toMatchObject({ status: "failed" });
    expect(calls).toHaveLength(1);
    expect(notifications).toEqual([]);
  });
});

describe("cross-process update lock", () => {
  test("reports contention and does not wait for a live owner", async () => {
    const { deps, calls } = await dependencies();
    await mkdir(deps.lockPath, { recursive: true });
    await writeFile(
      join(deps.lockPath, "owner.json"),
      JSON.stringify({ pid: 9001, startedAt: deps.now(), token: "other" }),
    );
    const { ui, statuses, notifications } = fakeUi();

    const result = await runBrewAutoUpdate("startup", ui, deps);

    expect(result.status).toBe("contended");
    expect(calls).toEqual([]);
    expect(statuses).toEqual([]);
    expect(notifications).toEqual([]);
  });

  test("recovers a lock whose owner process is dead", async () => {
    const { deps, calls } = await dependencies({ processAlive: () => false });
    await mkdir(deps.lockPath, { recursive: true });
    await writeFile(
      join(deps.lockPath, "owner.json"),
      JSON.stringify({ pid: 9001, startedAt: deps.now(), token: "dead" }),
    );

    const result = await runBrewAutoUpdate("startup", fakeUi().ui, deps);

    expect(result.status).toBe("complete");
    expect(calls).toHaveLength(3);
    await expect(stat(deps.lockPath)).rejects.toMatchObject({ code: "ENOENT" });
  });

  test("recovers a lock older than the bounded stale age", async () => {
    const { deps, calls } = await dependencies();
    await mkdir(deps.lockPath, { recursive: true });
    await writeFile(
      join(deps.lockPath, "owner.json"),
      JSON.stringify({ pid: 9001, startedAt: deps.now() - deps.staleLockMs - 1, token: "old" }),
    );

    expect((await runBrewAutoUpdate("startup", fakeUi().ui, deps)).status).toBe("complete");
    expect(calls).toHaveLength(3);
  });

  test("does not delete a replacement lock while releasing its own lock", async () => {
    const { deps } = await dependencies();
    let releaseFirstCommand!: () => void;
    deps.exec = async () => {
      await new Promise<void>((resolve) => {
        releaseFirstCommand = resolve;
      });
      return { code: 1, stdout: "", stderr: "stop", killed: false };
    };

    const running = runBrewAutoUpdate("manual", fakeUi().ui, deps);
    while (!releaseFirstCommand) await Bun.sleep(1);
    await writeFile(
      join(deps.lockPath, "owner.json"),
      JSON.stringify({ pid: 9999, startedAt: deps.now(), token: "replacement" }),
    );
    releaseFirstCommand();
    await running;

    const owner = JSON.parse(await readFile(join(deps.lockPath, "owner.json"), "utf8"));
    expect(owner.token).toBe("replacement");
  });
});

test("registers startup-only background execution and the manual command", async () => {
  const handlers = new Map<string, Function>();
  let commandHandler: Function | undefined;
  const fakePi = {
    on: (event: string, handler: Function) => handlers.set(event, handler),
    registerCommand: (name: string, options: { handler: Function }) => {
      expect(name).toBe("brew-auto-update-now");
      commandHandler = options.handler;
    },
  };
  let finishExec!: () => void;
  const { deps, calls } = await dependencies({
    exec: async (command, args) => {
      calls.push([command, args]);
      await new Promise<void>((resolve) => {
        finishExec = resolve;
      });
      return { code: 1, stdout: "", stderr: "stop", killed: false };
    },
  });

  registerBrewAutoUpdater(fakePi as never, deps);
  const startup = handlers.get("session_start")!;
  const ctx = { ui: fakeUi().ui };

  expect(startup({ reason: "reload" }, ctx)).toBeUndefined();
  expect(calls).toEqual([]);
  expect(startup({ reason: "startup" }, ctx)).toBeUndefined();
  while (!finishExec) await Bun.sleep(1);
  expect(calls).toHaveLength(1);
  finishExec();
  expect(commandHandler).toBeDefined();
});
