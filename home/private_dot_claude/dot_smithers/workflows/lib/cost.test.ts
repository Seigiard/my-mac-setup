import { describe, expect, test } from "bun:test";

import { aggregateUsage, type TokenUsageEvent } from "./cost.ts";

function ev(nodeId: string, model: string, inTok: number, outTok: number, cacheRead = 0): TokenUsageEvent {
  return { nodeId, model, inputTokens: inTok, outputTokens: outTok, cacheReadTokens: cacheRead };
}

describe("aggregateUsage", () => {
  test("суммирует токены и оценку USD по стадиям и итого", () => {
    // #given два плеча claude и одно opencode
    const events = [
      ev("work", "claude", 1_000_000, 0),
      ev("work", "claude", 0, 1_000_000),
      ev("review-opencode", "openai/gpt-5.5", 1_000_000, 0),
    ];

    // #when
    const usage = aggregateUsage(events);

    // #then
    expect(usage.stages.work.inputTokens).toBe(1_000_000);
    expect(usage.stages.work.outputTokens).toBe(1_000_000);
    expect(usage.stages.work.estUsd).toBeGreaterThan(0);
    expect(usage.totalTokens).toBe(3_000_000);
    expect(usage.totalEstUsd).toBeCloseTo(
      usage.stages.work.estUsd + usage.stages["review-opencode"].estUsd,
      6,
    );
  });

  test("cacheRead токены дешевле input-токенов", () => {
    const viaInput = aggregateUsage([ev("a", "claude", 1_000_000, 0)]).totalEstUsd;
    const viaCache = aggregateUsage([ev("a", "claude", 0, 0, 1_000_000)]).totalEstUsd;
    expect(viaCache).toBeLessThan(viaInput);
    expect(viaCache).toBeGreaterThan(0);
  });

  test("неизвестная модель → токены посчитаны, estUsd по дефолтной ставке", () => {
    const usage = aggregateUsage([ev("x", "mystery-model-9000", 500, 500)]);
    expect(usage.stages.x.inputTokens).toBe(500);
    expect(usage.totalEstUsd).toBeGreaterThan(0);
  });

  test("пустой список → нули", () => {
    const usage = aggregateUsage([]);
    expect(usage.totalTokens).toBe(0);
    expect(usage.totalEstUsd).toBe(0);
    expect(Object.keys(usage.stages).length).toBe(0);
  });
});
