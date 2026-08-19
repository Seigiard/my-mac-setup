import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, rmdir, stat, unlink, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const DEFAULT_TIMEOUT_MS = 5 * 60_000;
const DEFAULT_STALE_LOCK_MS = 20 * 60_000;
const OWNER_FILE = "owner.json";

type Trigger = "startup" | "manual";
type NotificationLevel = "info" | "warning" | "error";

export interface UpdateUi {
  setStatus(id: string, value: string | undefined): void;
  notify(message: string, level: NotificationLevel): void;
}

interface ExecResult {
  code: number | null;
  stdout: string;
  stderr: string;
  killed: boolean;
}

interface ExecOptions {
  timeout: number;
}

export interface BrewAutoUpdateDependencies {
  exec(command: string, args: string[], options: ExecOptions): Promise<ExecResult>;
  env: Record<string, string | undefined>;
  lockPath: string;
  now(): number;
  pid: number;
  processAlive(pid: number): boolean;
  token: string;
  timeoutMs: number;
  staleLockMs: number;
}

interface LockOwner {
  pid: number;
  startedAt: number;
  token: string;
}

interface AcquiredLock {
  acquired: true;
  release(): Promise<void>;
}

interface ContendedLock {
  acquired: false;
}

type UpdateLock = AcquiredLock | ContendedLock;

export interface UpdateResult {
  status: "complete" | "skipped" | "contended" | "failed";
  message: string;
}

type InstalledUpdate = "pi" | "extensions";

interface UpdateStep {
  command: string;
  args: string[];
  label: string;
  installedUpdate?: {
    kind: InstalledUpdate;
    pattern: RegExp;
  };
}

const UPDATE_STEPS: UpdateStep[] = [
  {
    command: "brew",
    args: ["update"],
    label: "Homebrew metadata refresh",
  },
  {
    command: "brew",
    args: ["upgrade", "pi-coding-agent"],
    label: "pi-coding-agent Homebrew upgrade",
    installedUpdate: {
      kind: "pi",
      pattern: /^==>\s+Upgrading(?:[^\n]*\n)?[^\n]*pi-coding-agent/im,
    },
  },
  {
    command: "pi",
    args: ["update", "--extensions"],
    label: "Pi package update",
    installedUpdate: {
      kind: "extensions",
      pattern: /^Updating .+\.\.\.$/m,
    },
  },
];

function defaultLockPath(env: Record<string, string | undefined>): string {
  const stateHome = env.XDG_STATE_HOME || join(homedir(), ".local", "state");
  return join(stateHome, "pi", "brew-auto-update.lock");
}

function defaultProcessAlive(pid: number): boolean {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

function createDefaultDependencies(pi: ExtensionAPI): BrewAutoUpdateDependencies {
  return {
    exec: (command, args, options) => pi.exec(command, args, options),
    env: process.env,
    lockPath: defaultLockPath(process.env),
    now: () => Date.now(),
    pid: process.pid,
    processAlive: defaultProcessAlive,
    token: randomUUID(),
    timeoutMs: DEFAULT_TIMEOUT_MS,
    staleLockMs: DEFAULT_STALE_LOCK_MS,
  };
}

function errorCode(error: unknown): string | undefined {
  return (error as NodeJS.ErrnoException | undefined)?.code;
}

async function readOwner(lockPath: string): Promise<LockOwner | undefined> {
  try {
    const parsed = JSON.parse(await readFile(join(lockPath, OWNER_FILE), "utf8")) as Partial<LockOwner>;
    if (
      Number.isSafeInteger(parsed.pid) &&
      typeof parsed.startedAt === "number" &&
      Number.isFinite(parsed.startedAt) &&
      typeof parsed.token === "string" &&
      parsed.token.length > 0
    ) {
      return parsed as LockOwner;
    }
  } catch {
    // A process can stop between the atomic directory create and owner write.
  }
  return undefined;
}

async function lockAge(lockPath: string, now: number, owner?: LockOwner): Promise<number> {
  if (owner) return Math.max(0, now - owner.startedAt);
  try {
    const lockStat = await stat(lockPath);
    return Math.max(0, now - lockStat.mtimeMs);
  } catch {
    return 0;
  }
}

async function removeLockDirectory(lockPath: string): Promise<void> {
  try {
    await unlink(join(lockPath, OWNER_FILE));
  } catch (error) {
    if (errorCode(error) !== "ENOENT") throw error;
  }
  await rmdir(lockPath);
}

async function reclaimStaleLock(lockPath: string, deps: BrewAutoUpdateDependencies): Promise<boolean> {
  const stalePath = `${lockPath}.stale-${deps.pid}-${deps.token}`;
  try {
    await rename(lockPath, stalePath);
  } catch (error) {
    if (errorCode(error) === "ENOENT" || errorCode(error) === "EEXIST") return false;
    throw error;
  }
  await removeLockDirectory(stalePath);
  return true;
}

async function acquireLock(deps: BrewAutoUpdateDependencies): Promise<UpdateLock> {
  await mkdir(dirname(deps.lockPath), { recursive: true });

  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      await mkdir(deps.lockPath);
      const owner: LockOwner = { pid: deps.pid, startedAt: deps.now(), token: deps.token };
      try {
        await writeFile(join(deps.lockPath, OWNER_FILE), `${JSON.stringify(owner)}\n`, {
          encoding: "utf8",
          flag: "wx",
        });
      } catch (error) {
        await removeLockDirectory(deps.lockPath).catch(() => {});
        throw error;
      }

      return {
        acquired: true,
        release: async () => {
          const currentOwner = await readOwner(deps.lockPath);
          if (currentOwner?.token !== deps.token) return;
          await removeLockDirectory(deps.lockPath).catch(() => {});
        },
      };
    } catch (error) {
      if (errorCode(error) !== "EEXIST") throw error;
    }

    const owner = await readOwner(deps.lockPath);
    const age = await lockAge(deps.lockPath, deps.now(), owner);
    const ownerIsDead = owner ? !deps.processAlive(owner.pid) : false;
    if (!ownerIsDead && age <= deps.staleLockMs) return { acquired: false };
    if (!(await reclaimStaleLock(deps.lockPath, deps))) return { acquired: false };
  }

  return { acquired: false };
}

function notify(ui: UpdateUi, message: string, level: NotificationLevel): void {
  try {
    ui.notify(message, level);
  } catch {
    // Headless modes can omit UI behavior. Updating remains best-effort.
  }
}

function failureDetail(result: ExecResult): string {
  const output = result.stderr.trim() || result.stdout.trim();
  if (!output) return `exit code ${result.code ?? "unknown"}`;
  return output.length > 500 ? `…${output.slice(-500)}` : output;
}

function reportFailure(message: string): UpdateResult {
  return { status: "failed", message };
}

function installedUpdateMessage(updates: Set<InstalledUpdate>): string | undefined {
  if (updates.has("pi") && updates.has("extensions")) {
    return "Pi and its extensions updated. Restart Pi to use them.";
  }
  if (updates.has("pi")) return "Pi updated. Restart Pi to use the new version.";
  if (updates.has("extensions")) return "Pi extensions updated. Restart Pi to use them.";
  return undefined;
}

export async function runBrewAutoUpdate(
  trigger: Trigger,
  ui: UpdateUi,
  deps: BrewAutoUpdateDependencies,
): Promise<UpdateResult> {
  if (deps.env.PI_OFFLINE === "1") {
    const message = "Pi update skipped: offline mode is active.";
    return { status: "skipped", message };
  }
  if (trigger === "startup" && deps.env.PI_BREW_AUTO_UPDATE === "0") {
    const message = "Pi startup update is disabled.";
    return { status: "skipped", message };
  }

  let lock: AcquiredLock | undefined;
  try {
    const candidate = await acquireLock(deps);
    if (!candidate.acquired) {
      const message = "Pi update skipped: another Pi process owns the update lock.";
      return { status: "contended", message };
    }
    lock = candidate;

    const installedUpdates = new Set<InstalledUpdate>();
    for (const step of UPDATE_STEPS) {
      let result: ExecResult;
      try {
        result = await deps.exec(step.command, [...step.args], { timeout: deps.timeoutMs });
      } catch (error) {
        const detail = error instanceof Error ? error.message : String(error);
        return reportFailure(`${step.label} failed: ${detail}`);
      }

      if (result.killed) {
        return reportFailure(
          `${step.label} timed out after ${Math.round(deps.timeoutMs / 60_000)} minutes.`,
        );
      }
      if (result.code !== 0) {
        return reportFailure(`${step.label} failed: ${failureDetail(result)}`);
      }
      if (step.installedUpdate?.pattern.test(`${result.stdout}\n${result.stderr}`)) {
        installedUpdates.add(step.installedUpdate.kind);
      }
    }

    const updateMessage = installedUpdateMessage(installedUpdates);
    if (updateMessage) notify(ui, updateMessage, "info");
    return { status: "complete", message: updateMessage ?? "Pi is up to date." };
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    return reportFailure(`Pi update failed without blocking startup: ${detail}`);
  } finally {
    await lock?.release();
  }
}

export default function registerBrewAutoUpdater(
  pi: ExtensionAPI,
  injectedDependencies?: BrewAutoUpdateDependencies,
): void {
  const deps = injectedDependencies ?? createDefaultDependencies(pi);

  pi.on("session_start", (event, ctx) => {
    if (event.reason !== "startup") return;
    void runBrewAutoUpdate("startup", ctx.ui, deps).catch(() => {
      // runBrewAutoUpdate reports failures itself. This guard prevents a
      // cleanup defect from becoming an unhandled startup rejection.
    });
  });

  pi.registerCommand("brew-auto-update-now", {
    description: "Update Homebrew-managed Pi and installed Pi packages now",
    handler: async (_args, ctx) => {
      await runBrewAutoUpdate("manual", ctx.ui, deps);
    },
  });
}
