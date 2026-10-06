// A real process at the updater boundary. Files are causal barriers, not timers.
import { appendFileSync, existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [modulePath, lockPath, root, label, deadPid] = process.argv.slice(2);

const { runBrewAutoUpdate } = await import(modulePath);

let assessed = false;

let entered = false;

function processAlive(pid: number): boolean {
  if (label === "b" && pid === Number(deadPid) && !assessed) {
    assessed = true;
    writeFileSync(join(root, "assessment-b"), "paused after reading the dead owner");
    const deadline = Date.now() + 10_000;

    while (!existsSync(join(root, "resume-assessment-b"))) {
      if (Date.now() > deadline) throw new Error("parent did not release the stale-owner assessment");
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
    }
  }

  try {
    process.kill(pid, 0);

    return true;
  } catch (error) {
    return error instanceof Error && "code" in error && error.code === "EPERM";
  }
}

const result = await runBrewAutoUpdate("manual", { notify() {} }, {
  exec: async (command: string, args: string[]) => {
    appendFileSync(join(root, `calls-${label}`), `${command} ${args.join(" ")}\n`);

    if (!entered) {
      entered = true;
      writeFileSync(join(root, `attempt-${label}`), "entered update");
      const deadline = Date.now() + 10_000;

      while (!existsSync(join(root, `resume-update-${label}`))) {
        if (Date.now() > deadline) throw new Error("parent did not release the active update");
        await Bun.sleep(10);
      }
    }

    return { code: 0, stdout: "", stderr: "", killed: false };
  },
  env: {},
  lockPath,
  now: Date.now,
  pid: process.pid,
  processAlive,
  token: label,
  timeoutMs: 10_000,
  staleLockMs: 1_200_000,
  snapshotExtensions: async () => new Map(),
});

writeFileSync(join(root, `result-${label}.json`), JSON.stringify(result));

writeFileSync(join(root, `attempt-${label}`), "returned");
