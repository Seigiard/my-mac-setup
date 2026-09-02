import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import type {
  BrewAutoUpdateDependencies,
  UpdateUi,
} from "../home/dot_pi/agent/extensions/brew-auto-update/index.ts";

const sourceRoot = process.env.SOURCE_ROOT ?? join(import.meta.dir, "../home");
const {
  default: registerBrewAutoUpdater,
  captureExtensionSnapshot,
  runBrewAutoUpdate,
} = await import(join(sourceRoot, "dot_pi/agent/extensions/brew-auto-update/index.ts"));

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
  const notifications: Array<{ message: string; level: string }> = [];
  const ui: UpdateUi = {
    notify: (message, level) => notifications.push({ message, level }),
  };
  return { ui, notifications };
}

// Distinct from DEFAULT_TIMEOUT_MS (5 * 60_000 = 300_000) in the extension
// source, so a handler that hardcodes the default cannot satisfy an
// assertion that the injected value was actually threaded through.
const INJECTED_TIMEOUT_MS = 111_222;

interface CapturedExecOptions {
  timeout: number;
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
    timeoutMs: INJECTED_TIMEOUT_MS,
    staleLockMs: 1_200_000,
    snapshotExtensions: async () => new Map(),
    ...overrides,
  };
  return { deps, calls };
}

describe("captureExtensionSnapshot", () => {
  async function setUpExtensionPackage(): Promise<{
    root: string;
    packagePath: string;
    lockPath: string;
    exec: BrewAutoUpdateDependencies["exec"];
  }> {
    const root = await mkdtemp(join(tmpdir(), "pi-extension-snapshot-test-"));
    cleanupPaths.push(root);
    const packagePath = join(root, "node_modules", "example-extension");
    await mkdir(packagePath, { recursive: true });
    await writeFile(
      join(packagePath, "package.json"),
      JSON.stringify({ name: "example-extension", version: "1.0.0" }),
    );
    const lockPath = join(root, "package-lock.json");
    await writeFile(lockPath, "old lock\n");
    const exec: BrewAutoUpdateDependencies["exec"] = async (command) => ({
      code: 0,
      stdout:
        command === "pi"
          ? `User packages:\n  npm:example-extension\n    ${packagePath}\n`
          : "",
      stderr: "",
      killed: false,
    });
    return { root, packagePath, lockPath, exec };
  }

  test("changes when the npm package's package.json content changes", async () => {
    const { packagePath, exec } = await setUpExtensionPackage();

    const before = await captureExtensionSnapshot(exec, 300_000);
    await writeFile(
      join(packagePath, "package.json"),
      JSON.stringify({ name: "example-extension", version: "1.0.1" }),
    );
    const after = await captureExtensionSnapshot(exec, 300_000);

    expect(before).toBeDefined();
    expect(after).toBeDefined();
    expect(after).not.toEqual(before);
  });

  test("changes when the lock-file content changes", async () => {
    const { lockPath, exec } = await setUpExtensionPackage();

    const before = await captureExtensionSnapshot(exec, 300_000);
    await writeFile(lockPath, "new lock\n");
    const after = await captureExtensionSnapshot(exec, 300_000);

    expect(before).toBeDefined();
    expect(after).toBeDefined();
    expect(after).not.toEqual(before);
  });

  test("stays the same when an unrelated file changes", async () => {
    const { root, exec } = await setUpExtensionPackage();

    const before = await captureExtensionSnapshot(exec, 300_000);
    await writeFile(join(root, "README.md"), "unrelated change\n");
    const after = await captureExtensionSnapshot(exec, 300_000);

    expect(before).toBeDefined();
    expect(after).toEqual(before);
  });
});

describe("brew auto update sequence", () => {
  test("stays silent at startup when successful commands install no updates", async () => {
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
    const { ui, notifications } = fakeUi();

    const result = await runBrewAutoUpdate("startup", ui, deps);

    expect(result.status).toBe("complete");
    expect(calls).toEqual([
      ["brew", ["update"]],
      ["brew", ["upgrade", "pi-coding-agent"]],
      ["pi", ["update", "--extensions"]],
    ]);
    expect(notifications).toEqual([]);
  });

  test("passes the independently injected timeout to every update subprocess", async () => {
    const execOptions: CapturedExecOptions[] = [];
    const { deps, calls } = await dependencies({
      exec: async (command, args, options) => {
        calls.push([command, args]);
        execOptions.push(options as CapturedExecOptions);
        return { code: 0, stdout: "", stderr: "", killed: false };
      },
    });
    const { ui } = fakeUi();

    const result = await runBrewAutoUpdate("manual", ui, deps);

    expect(result.status).toBe("complete");
    expect(calls).toHaveLength(3);
    expect(execOptions).toHaveLength(3);
    for (const options of execOptions) {
      expect(options).toEqual({ timeout: INJECTED_TIMEOUT_MS });
    }
  });

  test("stays silent at startup when a git extension remains on the same revision", async () => {
    const unchanged = new Map([["git:compound-engineering", "unchanged-commit"]]);
    const { deps } = await dependencies({
      snapshotExtensions: async () => new Map(unchanged),
      exec: async (command) => ({
        code: 0,
        stdout:
          command === "pi"
            ? "Updating git:github.com/EveryInc/compound-engineering-plugin...\nUpdated packages\n"
            : "",
        stderr: "",
        killed: false,
      }),
    });
    const { ui, notifications } = fakeUi();

    const result = await runBrewAutoUpdate("startup", ui, deps);

    expect(result).toEqual({ status: "complete", message: "Pi is up to date." });
    expect(notifications).toEqual([]);
  });

  test("manual command reports up-to-date outcome", async () => {
    const unchanged = new Map([["git:compound-engineering", "unchanged-commit"]]);
    const { deps } = await dependencies({
      snapshotExtensions: async () => new Map(unchanged),
      exec: async (command) => ({
        code: 0,
        stdout:
          command === "pi"
            ? "Updating git:github.com/EveryInc/compound-engineering-plugin...\nUpdated packages\n"
            : "",
        stderr: "",
        killed: false,
      }),
    });
    const { ui, notifications } = fakeUi();

    const result = await runBrewAutoUpdate("manual", ui, deps);

    expect(result).toEqual({ status: "complete", message: "Pi is up to date." });
    expect(notifications).toEqual([{ message: "Pi is up to date.", level: "info" }]);
  });

  test("notifies when a git extension advances to a new revision", async () => {
    let snapshots = 0;
    const { deps } = await dependencies({
      snapshotExtensions: async () => {
        snapshots += 1;
        return new Map([
          ["git:compound-engineering", snapshots === 1 ? "old-commit" : "new-commit"],
        ]);
      },
    });
    const { ui, notifications } = fakeUi();

    const result = await runBrewAutoUpdate("manual", ui, deps);

    expect(result.message).toBe("Pi extensions updated. Restart Pi to use them.");
    expect(notifications).toEqual([{ message: result.message, level: "info" }]);
  });

  test("notifies at startup too when a real update installs, unlike the silent up-to-date case", async () => {
    let snapshots = 0;
    const { deps } = await dependencies({
      snapshotExtensions: async () => {
        snapshots += 1;
        return new Map([
          ["git:compound-engineering", snapshots === 1 ? "old-commit" : "new-commit"],
        ]);
      },
    });
    const { ui, notifications } = fakeUi();

    const result = await runBrewAutoUpdate("startup", ui, deps);

    expect(result.message).toBe("Pi extensions updated. Restart Pi to use them.");
    expect(notifications).toEqual([{ message: result.message, level: "info" }]);
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
    let snapshots = 0;
    const { deps, calls } = await dependencies({
      snapshotExtensions: async () => {
        snapshots += 1;
        const revision = updated.label === "extensions" && snapshots === 2 ? "new" : "old";
        return new Map([["extension", revision]]);
      },
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
    const { ui, notifications } = fakeUi();

    const result = await runBrewAutoUpdate("manual", ui, deps);

    expect(result.status).toBe("complete");
    expect(notifications).toEqual([{ message: updated.message, level: "info" }]);
  });

  test("combines Pi and extension updates into one notification", async () => {
    let snapshots = 0;
    const { deps } = await dependencies({
      snapshotExtensions: async () => {
        snapshots += 1;
        return new Map([["extension", snapshots === 1 ? "old" : "new"]]);
      },
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
    const { ui, notifications } = fakeUi();

    await runBrewAutoUpdate("manual", ui, deps);

    expect(notifications).toEqual([
      {
        message: "Pi and its extensions updated. Restart Pi to use them.",
        level: "info",
      },
    ]);
  });

  test("stays silent at startup on an unknown extension state without a false update notification", async () => {
    const { deps } = await dependencies({
      snapshotExtensions: async () => undefined,
    });
    const { ui, notifications } = fakeUi();

    const result = await runBrewAutoUpdate("startup", ui, deps);

    expect(result).toEqual({
      status: "complete",
      message: "Pi package update completed; extension changes could not be verified.",
    });
    expect(notifications).toEqual([]);
  });

  test("skips all network work when PI_OFFLINE is set and reports it to a manual caller", async () => {
    const { deps, calls } = await dependencies({ env: { PI_OFFLINE: "1" } });
    const { ui, notifications } = fakeUi();

    const result = await runBrewAutoUpdate("manual", ui, deps);

    expect(result.status).toBe("skipped");
    expect(calls).toEqual([]);
    expect(notifications).toEqual([
      { message: "Pi update skipped: offline mode is active.", level: "info" },
    ]);
  });

  test("disables startup only when PI_BREW_AUTO_UPDATE is zero", async () => {
    const startup = await dependencies({ env: { PI_BREW_AUTO_UPDATE: "0" } });
    const manual = await dependencies({ env: { PI_BREW_AUTO_UPDATE: "0" } });

    expect((await runBrewAutoUpdate("startup", fakeUi().ui, startup.deps)).status).toBe("skipped");
    expect(startup.calls).toEqual([]);
    expect((await runBrewAutoUpdate("manual", fakeUi().ui, manual.deps)).status).toBe("complete");
    expect(manual.calls).toHaveLength(3);
  });

  test("stops after a timed-out command and notifies a manual caller of the failure", async () => {
    const execOptions: CapturedExecOptions[] = [];
    const { deps, calls } = await dependencies({
      exec: async (command, args, options) => {
        calls.push([command, args]);
        execOptions.push(options as CapturedExecOptions);
        return { code: null, stdout: "", stderr: "", killed: true };
      },
    });
    const { ui, notifications } = fakeUi();

    const result = await runBrewAutoUpdate("manual", ui, deps);

    expect(result.status).toBe("failed");
    expect(calls).toHaveLength(1);
    // The command that was killed must have been given the independently
    // injected timeout, not a hardcoded default, or this proves nothing about
    // which timeout the subprocess actually ran under.
    expect(execOptions).toEqual([{ timeout: INJECTED_TIMEOUT_MS }]);
    expect(notifications).toHaveLength(1);
    // The step that failed ("brew update") must be nameable by the user, not
    // just a private status enum, so they know what to investigate.
    expect(notifications[0]?.message).toContain("Homebrew metadata refresh");
    expect(notifications[0]?.message).toContain("timed out");
    expect(notifications[0]?.level).toBe("warning");
  });

  test("stops on command failure and notifies a manual caller without aborting the caller", async () => {
    const { deps, calls } = await dependencies({
      exec: async (command, args) => {
        calls.push([command, args]);
        return { code: 7, stdout: "", stderr: "network failed", killed: false };
      },
    });
    const { ui, notifications } = fakeUi();

    await expect(runBrewAutoUpdate("manual", ui, deps)).resolves.toMatchObject({ status: "failed" });
    expect(calls).toHaveLength(1);
    expect(notifications).toHaveLength(1);
    expect(notifications[0]?.message).toContain("Homebrew metadata refresh");
    expect(notifications[0]?.message).toContain("network failed");
    expect(notifications[0]?.level).toBe("warning");
  });

  test("notifies a manual caller when the update command itself throws", async () => {
    const { deps, calls } = await dependencies({
      exec: async (command, args) => {
        calls.push([command, args]);
        throw new Error("spawn brew ENOENT");
      },
    });
    const { ui, notifications } = fakeUi();

    const result = await runBrewAutoUpdate("manual", ui, deps);

    expect(result.status).toBe("failed");
    expect(calls).toHaveLength(1);
    expect(notifications).toHaveLength(1);
    expect(notifications[0]?.message).toContain("Homebrew metadata refresh");
    expect(notifications[0]?.message).toContain("spawn brew ENOENT");
    expect(notifications[0]?.level).toBe("warning");
  });

  test("startup reports a failure notification every time, unlike a silent success", async () => {
    const { deps } = await dependencies({
      exec: async () => ({ code: 7, stdout: "", stderr: "network failed", killed: false }),
    });
    const { ui, notifications } = fakeUi();

    const result = await runBrewAutoUpdate("startup", ui, deps);

    expect(result.status).toBe("failed");
    expect(notifications).toHaveLength(1);
    expect(notifications[0]?.message).toContain("Homebrew metadata refresh");
    expect(notifications[0]?.message).toContain("network failed");
    expect(notifications[0]?.level).toBe("warning");
  });

  test("startup notifies again on a second consecutive failure, proving there is no rate-limit", async () => {
    const { deps } = await dependencies({
      exec: async () => ({ code: 7, stdout: "", stderr: "network failed", killed: false }),
    });
    const { ui, notifications } = fakeUi();

    const first = await runBrewAutoUpdate("startup", ui, deps);
    const second = await runBrewAutoUpdate("startup", ui, deps);

    expect(first.status).toBe("failed");
    expect(second.status).toBe("failed");
    expect(notifications).toHaveLength(2);
    expect(notifications[0]?.level).toBe("warning");
    expect(notifications[1]?.level).toBe("warning");
  });

  test("manual command reports contention", async () => {
    const { deps, calls } = await dependencies();
    await mkdir(deps.lockPath, { recursive: true });
    await writeFile(
      join(deps.lockPath, "owner.json"),
      JSON.stringify({ pid: 9001, startedAt: deps.now(), token: "other" }),
    );
    const { ui, notifications } = fakeUi();

    const result = await runBrewAutoUpdate("manual", ui, deps);

    expect(result.status).toBe("contended");
    expect(calls).toEqual([]);
    expect(notifications).toEqual([
      {
        message: "Pi update skipped: a Pi update is already running.",
        level: "info",
      },
    ]);
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
    const { ui, notifications } = fakeUi();

    const result = await runBrewAutoUpdate("startup", ui, deps);

    expect(result.status).toBe("contended");
    expect(calls).toEqual([]);
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

test("registers session_start to run the update sequence in the background, only on a startup reason", async () => {
  const handlers = new Map<string, Function>();
  const fakePi = {
    on: (event: string, handler: Function) => handlers.set(event, handler),
    registerCommand: (name: string, options: { handler: Function }) => {
      expect(name).toBe("brew-auto-update-now");
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
});

test("invokes the registered brew-auto-update-now handler and runs the full update sequence through the fake executor", async () => {
  const handlers = new Map<string, Function>();
  let commandHandler: Function | undefined;
  const fakePi = {
    on: (event: string, handler: Function) => handlers.set(event, handler),
    registerCommand: (name: string, options: { handler: Function }) => {
      if (name === "brew-auto-update-now") commandHandler = options.handler;
    },
  };
  const { deps, calls } = await dependencies({
    exec: async (command, args) => {
      calls.push([command, args]);
      return {
        code: 0,
        stdout: command === "pi" ? "Updated packages\n" : "",
        stderr: "",
        killed: false,
      };
    },
  });

  registerBrewAutoUpdater(fakePi as never, deps);
  expect(commandHandler).toBeDefined();

  const { ui } = fakeUi();
  // The real handler.handler signature is (args, ctx); a bare {} stands in
  // for command args the update sequence never reads.
  await commandHandler!({}, { ui });

  // Observed through the fake executor: this is the actual command sequence
  // the registered handler drove end to end, in order, not just proof that a
  // handler function was registered.
  expect(calls).toEqual([
    ["brew", ["update"]],
    ["brew", ["upgrade", "pi-coding-agent"]],
    ["pi", ["update", "--extensions"]],
  ]);
});
