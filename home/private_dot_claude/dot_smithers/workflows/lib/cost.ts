// Run cost accounting (R8/KTD6, U6→U9-Батч4). Adapters persist per-task
// TOKENS only (TokenUsageReported events); no adapter fills USD. Tokens are
// therefore the authoritative metric; estUsd is an APPROXIMATION priced by
// the official smithers-orchestrator/scorers table (estimateCostUsd /
// modelTokenPrices) instead of a hand-rolled copy. The single authoritative
// store is the run's summary output, which embeds this aggregation;
// `se list` and audits read only from there.

import { Database } from "bun:sqlite";
import { existsSync, statSync } from "node:fs";
import { dirname, join } from "node:path";

import { estimateCostUsd, modelTokenPrices } from "smithers-orchestrator/scorers";

// Unknown ids price at $0 in the official table, but a real leg is never
// free — the CLI just failed to report a concrete id (bare "claude", null,
// or a model newer than the table). Price those at sonnet-class.
const FALLBACK_MODEL = "claude-sonnet-5";

export interface TokenUsageEvent {
  nodeId: string;
  model: string | null;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens?: number;
}

export interface StageUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  estUsd: number;
}

export interface RunUsage {
  stages: Record<string, StageUsage>;
  totalTokens: number;
  totalEstUsd: number;
}

// The event log reports models as the agent CLI names them
// ("openai/gpt-5.6-terra"); the price table keys bare ids.
function pricedModel(model: string | null): string {
  const bare = (model ?? "").replace(/^[a-z0-9_-]+\//i, "");
  const price = modelTokenPrices(bare);
  const isFree = price.input === 0 && price.output === 0 && price.cacheRead === 0 && price.cacheWrite === 0;
  return isFree ? FALLBACK_MODEL : bare;
}

export function aggregateUsage(events: TokenUsageEvent[]): RunUsage {
  const stages: Record<string, StageUsage> = {};
  let totalTokens = 0;
  let totalEstUsd = 0;

  for (const event of events) {
    const cacheWriteTokens = event.cacheWriteTokens ?? 0;
    const estUsd = estimateCostUsd({
      model: pricedModel(event.model),
      inputTokens: event.inputTokens,
      outputTokens: event.outputTokens,
      cacheReadTokens: event.cacheReadTokens,
      cacheWriteTokens,
    });

    const stage = (stages[event.nodeId] ??= {
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
      estUsd: 0,
    });
    stage.inputTokens += event.inputTokens;
    stage.outputTokens += event.outputTokens;
    stage.cacheReadTokens += event.cacheReadTokens;
    stage.cacheWriteTokens += cacheWriteTokens;
    stage.estUsd += estUsd;

    totalTokens += event.inputTokens + event.outputTokens + event.cacheReadTokens + cacheWriteTokens;
    totalEstUsd += estUsd;
  }

  return { stages, totalTokens, totalEstUsd };
}

// Reads this run's TokenUsageReported events, plus its subflow children's, from
// the persisted event log — the only place the engine keeps usage.
//
// Fail-soft to an empty list on every error, deliberately. Cost is advisory
// (KTD6: tokens are the metric, USD an estimate), so a run must never die over
// missing telemetry. The caller decides what an empty result means; for the
// budget gate it means "no measured spend", which cannot breach a ceiling.
//
// The database is resolved upward from the launch directory: the engine's
// state resolver can persist smithers.db one level ABOVE it, and a fresh
// database has no _smithers_events table until the first event lands.
//
// The opener is injected so the reader stays testable without a real database;
// production callers pass `openUsageDb` below.
export function readRunUsage(runId: string, launchDir: string, openDatabase: (dbPath: string) => UsageQueryable | null): TokenUsageEvent[] {
  for (const dbPath of [launchDir, dirname(launchDir)].map((d) => join(d, "smithers.db"))) {
    const db = openDatabase(dbPath);
    if (db === null) continue;
    try {
      return db
        .rows(
          "SELECT payload_json FROM _smithers_events WHERE type='TokenUsageReported' AND (run_id = ?1 OR run_id LIKE ?1 || ':child:%')",
          runId,
        )
        .map((row) => {
          const p = JSON.parse(row.payload_json) as Record<string, unknown>;
          return {
            nodeId: String(p.nodeId ?? "unknown"),
            model: typeof p.model === "string" ? p.model : null,
            inputTokens: Number(p.inputTokens ?? 0),
            outputTokens: Number(p.outputTokens ?? 0),
            cacheReadTokens: Number(p.cacheReadTokens ?? 0),
            cacheWriteTokens: Number(p.cacheWriteTokens ?? 0),
          };
        });
    } catch {
      continue;
    } finally {
      db.close();
    }
  }
  return [];
}

export interface UsageQueryable {
  rows: (sql: string, runId: string) => Array<{ payload_json: string }>;
  close: () => void;
}

// Opens a run state database read-only. Returns null on every failure so
// `readRunUsage` falls through to the next candidate path instead of throwing:
// cost is advisory (KTD6), and a run must not die because telemetry is missing.
// A zero-byte file is a database the engine created but never wrote to.
export function openUsageDb(dbPath: string): UsageQueryable | null {
  try {
    if (!existsSync(dbPath) || statSync(dbPath).size === 0) return null;
    const db = new Database(dbPath, { readonly: true });
    return {
      rows: (sql: string, runId: string) => db.query(sql).all(runId) as Array<{ payload_json: string }>,
      close: () => db.close(),
    };
  } catch {
    return null;
  }
}

export interface BudgetState {
  spentUsd: number;
  breached: boolean;
}

// KTD9: a breach PARKS the run for an operator ack, it never hard-kills. A null
// or non-positive ceiling means the operator set none, which is not a ceiling of
// zero — every run would park immediately.
export function evaluateBudget(spentUsd: number, ceilingUsd: number | null | undefined): BudgetState {
  const ceiling = typeof ceilingUsd === "number" && ceilingUsd > 0 ? ceilingUsd : null;
  return { spentUsd, breached: ceiling !== null && spentUsd > ceiling };
}

// Floor for a per-agent cap. A block whose cost profile is optimistic still gets
// enough room to finish one leg; below a few dollars a claude leg dies mid-answer.
const AGENT_CAP_FLOOR_USD = 5;
const AGENT_CAP_HEADROOM = 2;

// The hard stop the agent CLI enforces on ONE leg, derived from that block's own
// cost profile. Deliberately NOT the run's budget ceiling: they are different
// mechanisms pointing opposite ways. The run ceiling is a parking threshold that
// KTD9 says must never kill; the agent cap is a kill. Wiring the ceiling into
// the cap made every leg hard-kill at exactly the point KTD9 says to park, and
// a run launched without `--budget` passed a cap of $0, which killed any agent
// leg on its first token.
export function agentCapUsd(estUsd: number): number {
  const scaled = Number.isFinite(estUsd) && estUsd > 0 ? estUsd * AGENT_CAP_HEADROOM : 0;
  return Math.max(AGENT_CAP_FLOOR_USD, scaled);
}
