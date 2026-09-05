// Selfcheck: runtime liveness and deployed-vs-loaded identity (R8, KTD5).
//
// Liveness is a real dispatch of a registry-derived known-bad canary through
// each block-capable (policy, client) route — not registry introspection, which
// would pass with every policy dead. Identity comes from per-session markers
// written by the in-process adapters at import time; without marker evidence a
// resident client is reported unknown, never current.

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
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
    hash.update(path.slice(dir.length));
    hash.update(readFileSync(path));
  }
  return hash.digest("hex").slice(0, 16);
}

export type Marker = { client: string; pid: number; hash: string; loadedAt: string };

export function markerPath(stateDir: string, client: string, pid: number): string {
  return join(stateDir, `${client}-${pid}.json`);
}

/** Called by each in-process adapter once the core import succeeds (KTD5). */
export function writeMarker(
  client: string,
  options: { stateDir?: string; pid?: number; hash?: string } = {},
): Marker {
  const stateDir = options.stateDir ?? DEFAULT_STATE_DIR;
  const marker: Marker = {
    client,
    pid: options.pid ?? process.pid,
    hash: options.hash ?? coreHash(),
    loadedAt: new Date().toISOString(),
  };
  mkdirSync(stateDir, { recursive: true });
  writeFileSync(markerPath(stateDir, marker.client, marker.pid), `${JSON.stringify(marker)}\n`);
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
};

export type IdentityOptions = {
  stateDir?: string;
  deployedHash?: string;
  clients?: string[];
  markerlessClients?: string[];
  isAlive?: (pid: number) => boolean;
};

/**
 * A marker from a dead process is not evidence of anything and is dropped. A
 * resident client with no live marker is unknown, not current: multiple herdr
 * panes are the normal case, so silence never means agreement.
 */
export function inspectIdentity(options: IdentityOptions = {}): {
  deployedHash: string;
  clients: ClientIdentity[];
} {
  const stateDir = options.stateDir ?? DEFAULT_STATE_DIR;
  const deployedHash = options.deployedHash ?? coreHash();
  const isAlive = options.isAlive ?? processIsAlive;
  const markerless = options.markerlessClients ?? MARKERLESS_CLIENTS;
  const clients = options.clients ?? CORE_REGISTRY.profiles.map((profile) => profile.client);
  const markers = readMarkers(stateDir).filter((marker) => isAlive(marker.pid));

  return {
    deployedHash,
    clients: clients.map((client) => {
      if (markerless.includes(client)) {
        return { client, status: "per-call" as IdentityStatus, live: [], stale: [] };
      }
      const live = markers.filter((marker) => marker.client === client);
      const stale = live.filter((marker) => marker.hash !== deployedHash);
      const status: IdentityStatus =
        live.length === 0 ? "unknown" : stale.length > 0 ? "stale" : "current";
      return { client, status, live, stale };
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
    lines.push(
      `  ${client.client}: ${client.status}${sessions ? ` — stale sessions: ${sessions}` : ""}`,
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
