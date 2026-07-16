import { describe, expect, test } from "bun:test";

import { aggregateUsage, type TokenUsageEvent } from "./cost.ts";

function ev(
  nodeId: string,
  model: string | null,
  inTok: number,
  outTok: number,
  cacheRead = 0,
  cacheWrite = 0,
): TokenUsageEvent {
  return {
    nodeId,
    model,
    inputTokens: inTok,
    outputTokens: outTok,
    cacheReadTokens: cacheRead,
    cacheWriteTokens: cacheWrite,
  };
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

  test("известная модель прайсится по официальной таблице (sonnet-5: $3/$15 за MTok)", () => {
    // #given 1M input + 1M output на claude-sonnet-5
    const usage = aggregateUsage([ev("work", "claude-sonnet-5", 1_000_000, 1_000_000)]);

    // #then 3 + 15 = 18 USD
    expect(usage.totalEstUsd).toBeCloseTo(18, 6);
  });

  test("opus-4-8 дороже sonnet-5 по официальной таблице ($5/$25 за MTok)", () => {
    const usage = aggregateUsage([ev("work", "claude-opus-4-8", 1_000_000, 1_000_000)]);
    expect(usage.totalEstUsd).toBeCloseTo(30, 6);
  });

  test("провайдер-префикс срезается перед лукапом (openai/gpt-5.6-terra → $2.5/MTok input)", () => {
    // #given 100K input — ниже порога long-context (272K), множители не применяются
    const usage = aggregateUsage([ev("review-opencode", "openai/gpt-5.6-terra", 100_000, 0)]);
    expect(usage.totalEstUsd).toBeCloseTo(0.25, 6);
  });

  test("date-stamp суффикс модели матчится (claude-sonnet-5-20260203)", () => {
    const usage = aggregateUsage([ev("work", "claude-sonnet-5-20260203", 1_000_000, 0)]);
    expect(usage.totalEstUsd).toBeCloseTo(3, 6);
  });

  test("cacheRead токены дешевле input-токенов", () => {
    const viaInput = aggregateUsage([ev("a", "claude-sonnet-5", 1_000_000, 0)]).totalEstUsd;
    const viaCache = aggregateUsage([ev("a", "claude-sonnet-5", 0, 0, 1_000_000)]).totalEstUsd;
    expect(viaCache).toBeLessThan(viaInput);
    expect(viaCache).toBeGreaterThan(0);
  });

  test("cacheWrite токены прайсятся и входят в totalTokens (sonnet-5: $3.75/MTok)", () => {
    const usage = aggregateUsage([ev("a", "claude-sonnet-5", 0, 0, 0, 1_000_000)]);
    expect(usage.totalEstUsd).toBeCloseTo(3.75, 6);
    expect(usage.totalTokens).toBe(1_000_000);
  });

  test("неизвестная модель → fallback sonnet-класс, НЕ бесплатно", () => {
    // #given модель вне официальной таблицы
    const unknown = aggregateUsage([ev("x", "mystery-model-9000", 500, 500)]);
    const sonnet = aggregateUsage([ev("x", "claude-sonnet-5", 500, 500)]);

    // #then токены посчитаны, цена = sonnet-класс
    expect(unknown.stages.x.inputTokens).toBe(500);
    expect(unknown.totalEstUsd).toBeCloseTo(sonnet.totalEstUsd, 9);
    expect(unknown.totalEstUsd).toBeGreaterThan(0);
  });

  test("голый 'claude' и null-модель → тот же sonnet-fallback", () => {
    const bare = aggregateUsage([ev("a", "claude", 1_000, 1_000)]).totalEstUsd;
    const nul = aggregateUsage([ev("a", null, 1_000, 1_000)]).totalEstUsd;
    const sonnet = aggregateUsage([ev("a", "claude-sonnet-5", 1_000, 1_000)]).totalEstUsd;
    expect(bare).toBeCloseTo(sonnet, 9);
    expect(nul).toBeCloseTo(sonnet, 9);
  });

  test("пустой список → нули", () => {
    const usage = aggregateUsage([]);
    expect(usage.totalTokens).toBe(0);
    expect(usage.totalEstUsd).toBe(0);
    expect(Object.keys(usage.stages).length).toBe(0);
  });
});
