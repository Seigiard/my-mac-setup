// Run cost accounting (R8/KTD6, U6→U9-Батч4). Adapters persist per-task
// TOKENS only (TokenUsageReported events); no adapter fills USD. Tokens are
// therefore the authoritative metric; estUsd is an APPROXIMATION priced by
// the official smithers-orchestrator/scorers table (estimateCostUsd /
// modelTokenPrices) instead of a hand-rolled copy. The single authoritative
// store is the run's summary output, which embeds this aggregation;
// `se list` and audits read only from there.

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
