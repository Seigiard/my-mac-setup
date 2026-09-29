// Selfcheck: runtime liveness and deployed-vs-loaded identity (R8, KTD5).
//
// Liveness is a real dispatch of a registry-derived known-bad canary through
// each block-capable (policy, client) route — not registry introspection, which
// would pass with every policy dead. Identity comes from per-session markers
// written by the in-process adapters at import time; without marker evidence a
// resident client is reported unknown, never current.

import { execFileSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { dispatch } from "./index.ts";
import { encodeEvent } from "./normalize.ts";
import { CORE_REGISTRY, applicableClients, isBlockCapable, registrySnapshot } from "./registry.ts";
import type { ClientId, Decision, Registry } from "./types.ts";

export const CORE_DIR = dirname(fileURLToPath(import.meta.url));
export const DEFAULT_STATE_DIR = join(homedir(), ".local", "state", "agent-hooks");

// Claude runs the core as a fresh subprocess per tool call, so it has no loaded
// identity to skew and writes no marker.
export const MARKERLESS_CLIENTS: ClientId[] = ["claude"];

function sourceFiles(dir: string): string[] {
  const found: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) found.push(...sourceFiles(path));
    else if (entry.name.endsWith(".ts")) found.push(path);
  }
  return found.sort();
}

/** Content hash of the deployed core; the identity a marker records. */
export function coreHash(dir: string = CORE_DIR): string {
  const hash = createHash("sha256");
  for (const path of sourceFiles(dir)) {
    // Older deployments can retain the retired test corpus after source removal.
    if (path === join(dir, "fixtures.ts")) continue;
    hash.update(path.slice(dir.length));
    hash.update(readFileSync(path));
  }
  return hash.digest("hex").slice(0, 16);
}

export type Marker = {
  client: string;
  pid: number;
  hash: string;
  loadedAt: string;
  processStartedAt?: string | null;
};

type ProcessProbe = {
  isAlive?: (pid: number) => boolean;
  getProcessStart?: (pid: number) => string | null;
};

/** ps exposes OS start time on macOS and Linux, at one-second resolution. */
export function processStartTime(pid: number): string | null {
  if (!Number.isSafeInteger(pid) || pid <= 0 || pid > 2147483647) return null;
  try {
    return execFileSync("ps", ["-p", String(pid), "-o", "lstart="], {
      encoding: "utf8",
      env: { ...process.env, LC_ALL: "C", TZ: "UTC" },
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 1000,
    }).trim() || null;
  } catch {
    // A missing process, unavailable ps, or failed probe is not identity evidence.
    return null;
  }
}

function matchesProcessStart(marker: Marker, getStart: (pid: number) => string | null): boolean | null {
  if (typeof marker.processStartedAt !== "string" || marker.processStartedAt.length === 0) return null;
  const current = getStart(marker.pid);
  return current ? current === marker.processStartedAt : null;
}

export function markerPath(stateDir: string, client: string, pid: number, startedAt: string | null): string {
  // Start-specific names keep cleanup of an old record away from its replacement.
  // An unverifiable start gets its own filename rather than sharing a null identity.
  const generation = createHash("sha256").update(startedAt ?? randomUUID()).digest("hex");
  return join(stateDir, `${client}-${pid}-${generation}.json`);
}

/** Called by each in-process adapter once the core import succeeds (KTD5).
 * Collect dead or replaced same-client markers so identity inspection stays read-only.
 */
export function writeMarker(
  client: string,
  options: { stateDir?: string; pid?: number; hash?: string } & ProcessProbe = {},
): Marker {
  const stateDir = options.stateDir ?? DEFAULT_STATE_DIR;
  const getStart = options.getProcessStart ?? processStartTime;
  const pid = options.pid ?? process.pid;
  const marker: Marker = {
    client,
    pid,
    hash: options.hash ?? coreHash(),
    loadedAt: new Date().toISOString(),
    processStartedAt: getStart(pid),
  };
  const path = markerPath(stateDir, marker.client, marker.pid, marker.processStartedAt ?? null);
  mkdirSync(stateDir, { recursive: true });
  const isAlive = options.isAlive ?? processIsAlive;
  let entries: string[] = [];
  try {
    entries = readdirSync(stateDir);
  } catch {
    // Listing is optional for cleanup; write permission can still be available.
  }
  for (const name of entries) {
    if (!name.startsWith(`${client}-`)) continue;
    const match = /^([1-9]\d*)(?:-[a-f0-9]{64})?\.json$/.exec(name.slice(client.length + 1));
    if (!match) continue;
    const pid = Number(match[1]);
    if (!Number.isSafeInteger(pid) || join(stateDir, name) === path) continue;
    try {
      // This process supersedes its own legacy or unverifiable records.
      if (pid !== marker.pid && isAlive(pid)) {
        const previous = JSON.parse(readFileSync(join(stateDir, name), "utf8"));
        if (previous?.client !== client || previous?.pid !== pid ||
            matchesProcessStart(previous, getStart) !== false) continue;
      }
      unlinkSync(join(stateDir, name));
    } catch {
      // Cleanup is best-effort: another startup may have removed the file,
      // or an old marker may be unwritable. Neither should block this session.
    }
  }
  writeFileSync(path, `${JSON.stringify(marker)}\n`);
  return marker;
}

export function readMarkers(stateDir: string): Marker[] {
  if (!existsSync(stateDir) || !statSync(stateDir).isDirectory()) return [];
  const markers: Marker[] = [];
  for (const name of readdirSync(stateDir)) {
    if (!name.endsWith(".json")) continue;
    try {
      const parsed = JSON.parse(readFileSync(join(stateDir, name), "utf8"));
      if (typeof parsed?.client === "string" && Number.isInteger(parsed?.pid) && typeof parsed?.hash === "string") {
        markers.push(parsed as Marker);
      }
    } catch {
      // A truncated or foreign file is not evidence; ignore it.
    }
  }
  return markers;
}

export function processIsAlive(pid: number): boolean {
  if (!Number.isSafeInteger(pid) || pid <= 0 || pid > 2147483647) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error: any) {
    return error?.code === "EPERM";
  }
}

export type IdentityStatus = "current" | "stale" | "unknown" | "per-call";
export type ClientIdentity = {
  client: string;
  status: IdentityStatus;
  live: Marker[];
  stale: Marker[];
  uncertain: Marker[];
};

export type IdentityOptions = ProcessProbe & {
  stateDir?: string;
  deployedHash?: string;
  clients?: string[];
  markerlessClients?: string[];
};

/**
 * Dead or replaced processes are not evidence. Unverifiable live markers keep
 * a client unknown unless a confirmed stale session already proves core skew.
 */
export function inspectIdentity(options: IdentityOptions = {}): {
  deployedHash: string;
  clients: ClientIdentity[];
} {
  const stateDir = options.stateDir ?? DEFAULT_STATE_DIR;
  const deployedHash = options.deployedHash ?? coreHash();
  const isAlive = options.isAlive ?? processIsAlive;
  const getStart = options.getProcessStart ?? processStartTime;
  const markerless = options.markerlessClients ?? MARKERLESS_CLIENTS;
  const clients = options.clients ?? CORE_REGISTRY.profiles.map((profile) => profile.client);
  const markers = readMarkers(stateDir)
    .filter((marker) => isAlive(marker.pid))
    .map((marker) => ({ marker, matches: matchesProcessStart(marker, getStart) }));

  return {
    deployedHash,
    clients: clients.map((client) => {
      if (markerless.includes(client)) {
        return { client, status: "per-call" as IdentityStatus, live: [], stale: [], uncertain: [] };
      }
      const candidates = markers.filter(({ marker }) => marker.client === client);
      const live = candidates.filter(({ matches }) => matches === true).map(({ marker }) => marker);
      const stale = live.filter((marker) => marker.hash !== deployedHash);
      const uncertain = candidates.filter(({ matches }) => matches === null).map(({ marker }) => marker);
      const status: IdentityStatus =
        stale.length > 0 ? "stale" : live.length === 0 || uncertain.length > 0 ? "unknown" : "current";
      return { client, status, live, stale, uncertain };
    }),
  };
}

export type CanaryResult = {
  policy: string;
  client: ClientId;
  ok: boolean;
  detail: string;
  decision?: Decision;
};

/**
 * Dispatch each block-capable policy's known-bad fixture through every client
 * route it is applicable on. The canary runs with an empty environment so a
 * session-level AGENT_HOOKS_DISABLE cannot make a dead route look alive.
 */
export function runCanaries(registry: Registry = CORE_REGISTRY): CanaryResult[] {
  const results: CanaryResult[] = [];
  for (const policy of registry.policies) {
    if (!isBlockCapable(policy)) continue;
    for (const client of applicableClients(registry, policy)) {
      if (!policy.canary) {
        results.push({ policy: policy.name, client, ok: false, detail: "no canary fixture declared" });
        continue;
      }
      const raw = encodeEvent(client, policy.canary.tool, policy.canary.payload, registry);
      if (raw === undefined) {
        results.push({ policy: policy.name, client, ok: false, detail: "no client route for canary tool" });
        continue;
      }
      const decision = dispatch(client, raw, { registry, env: {} });
      results.push({
        policy: policy.name,
        client,
        ok: decision.verdict === "block",
        detail: decision.verdict === "block" ? "blocked" : `expected block, got ${decision.verdict}`,
        decision,
      });
    }
  }
  return results;
}

export type SelfcheckReport = {
  runtime: { bun: string | null };
  coreDir: string;
  deployedHash: string;
  registry: ReturnType<typeof registrySnapshot>;
  canaries: CanaryResult[];
  identity: ReturnType<typeof inspectIdentity>;
  ok: boolean;
};

export function selfcheck(
  registry: Registry = CORE_REGISTRY,
  options: IdentityOptions = {},
): SelfcheckReport {
  const deployedHash = options.deployedHash ?? coreHash();
  const canaries = runCanaries(registry);
  const identity = inspectIdentity({ ...options, deployedHash });
  return {
    runtime: { bun: process.versions?.bun ?? null },
    coreDir: CORE_DIR,
    deployedHash,
    registry: registrySnapshot(registry),
    canaries,
    identity,
    ok: canaries.every((result) => result.ok),
  };
}

export function formatReport(report: SelfcheckReport): string {
  const lines = [
    `agent-hooks core ${report.coreDir}`,
    `runtime: bun ${report.runtime.bun ?? "unknown"}`,
    `deployed hash: ${report.deployedHash}`,
    `policies: ${report.registry.policies.length}`,
  ];
  lines.push(report.canaries.length === 0 ? "canaries: none registered" : "canaries:");
  for (const result of report.canaries) {
    lines.push(`  [${result.ok ? "ok" : "FAIL"}] ${result.policy} @ ${result.client}: ${result.detail}`);
  }
  lines.push("loaded identity:");
  for (const client of report.identity.clients) {
    const sessions = client.stale.map((marker) => `pid ${marker.pid} (${marker.hash})`).join(", ");
    const unverified = client.uncertain.map((marker) => `pid ${marker.pid} (${marker.hash})`).join(", ");
    lines.push(
      `  ${client.client}: ${client.status}${sessions ? ` — stale sessions: ${sessions}` : ""}` +
      (unverified ? ` — unverified sessions: ${unverified}` : ""),
    );
  }
  lines.push(report.ok ? "result: ok" : "result: FAILED");
  return lines.join("\n");
}

export function main(argv: string[] = process.argv.slice(2)): number {
  const report = selfcheck();
  process.stdout.write(argv.includes("--json") ? `${JSON.stringify(report, null, 2)}\n` : `${formatReport(report)}\n`);
  return report.ok ? 0 : 1;
}

if (import.meta.main) process.exit(main());
