// Run cost accounting (R8/KTD6, U6). 0.27.0 persists per-task TOKENS only
// (TokenUsageReported events); no adapter fills USD (U1 spike verdict, е).
// Tokens are therefore the authoritative metric; estUsd is an APPROXIMATION
// from the price table below — update it when provider pricing changes.
// The single authoritative store is the run's summary output, which embeds
// this aggregation; `se list` and audits read only from there.

export interface TokenUsageEvent {
  nodeId: string;
  model: string | null;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
}

export interface StageUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  estUsd: number;
}

export interface RunUsage {
  stages: Record<string, StageUsage>;
  totalTokens: number;
  totalEstUsd: number;
}

interface PriceRow {
  match: string;
  inputPerMTok: number;
  outputPerMTok: number;
  cacheReadPerMTok: number;
}

// USD per million tokens, matched by model-string prefix. Approximate
// (sonnet-class for bare "claude": the CLI reports no concrete model id).
const PRICE_TABLE: PriceRow[] = [
  { match: "openai/", inputPerMTok: 1.25, outputPerMTok: 10, cacheReadPerMTok: 0.125 },
  { match: "claude", inputPerMTok: 3, outputPerMTok: 15, cacheReadPerMTok: 0.3 },
];

const DEFAULT_PRICE: PriceRow = { match: "", inputPerMTok: 3, outputPerMTok: 15, cacheReadPerMTok: 0.3 };

export function aggregateUsage(events: TokenUsageEvent[]): RunUsage {
  const stages: Record<string, StageUsage> = {};
  let totalTokens = 0;
  let totalEstUsd = 0;

  for (const event of events) {
    const price = PRICE_TABLE.find((row) => (event.model ?? "").startsWith(row.match)) ?? DEFAULT_PRICE;
    const estUsd =
      (event.inputTokens * price.inputPerMTok +
        event.outputTokens * price.outputPerMTok +
        event.cacheReadTokens * price.cacheReadPerMTok) /
      1_000_000;

    const stage = (stages[event.nodeId] ??= { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, estUsd: 0 });
    stage.inputTokens += event.inputTokens;
    stage.outputTokens += event.outputTokens;
    stage.cacheReadTokens += event.cacheReadTokens;
    stage.estUsd += estUsd;

    totalTokens += event.inputTokens + event.outputTokens + event.cacheReadTokens;
    totalEstUsd += estUsd;
  }

  return { stages, totalTokens, totalEstUsd };
}
