import { describe, expect, test } from "bun:test";

import {
  appendEscapeAdvisory,
  codeReviewGate,
  docReviewGate,
  emptyCoverageNotes,
  emptyCoverageReason,
  emptyCoverageSignals,
  mainCheckoutEscapeReason,
  planGate,
  rescanGate,
  workGate,
} from "./gates.ts";

const validPlan = `---
title: Fixture - Plan
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
---

# Fixture
`;

const requirementsOnlyPlan = validPlan.replace("implementation-ready", "requirements-only");

function workEnvelope(overrides: Record<string, unknown> = {}): string {
  return JSON.stringify({
    status: "complete",
    plan_path: "/abs/plan.md",
    changed_files: ["src/a.ts"],
    u_ids_attempted: ["U1"],
    u_ids_completed: ["U1"],
    verification_results: { "bun test": "green" },
    verification_evidence: [{ unit: "U1", behavior_changed: true }],
    blockers: [],
    behavior_change: true,
    standalone_shipping_skipped: true,
    final_commit_sha: "a".repeat(40),
    ...overrides,
  });
}

function reviewReport(p0: number, p1: number): string {
  const findings = [
    ...Array.from({ length: p0 }, (_, i) => ({ severity: "P0", title: `p0-${i}` })),
    ...Array.from({ length: p1 }, (_, i) => ({ severity: "P1", title: `p1-${i}` })),
  ];
  return JSON.stringify({ status: "complete", verdict: p0 ? "request_changes" : "approve", findings });
}

describe("planGate (гейт-0, KTD7)", () => {
  test("валидный implementation-ready план → ok со стабильным hash", () => {
    const a = planGate(validPlan, "branch");
    const b = planGate(validPlan, "branch");
    if (!a.ok || !b.ok) throw new Error("expected ok");
    expect(a.hash).toMatch(/^[0-9a-f]{64}$/);
    expect(a.hash).toBe(b.hash);
  });

  test("requirements-only план → отказ с причиной (AE4)", () => {
    const r = planGate(requirementsOnlyPlan, "branch");
    expect(r.ok).toBe(false);
    if (r.ok) throw new Error("expected refusal");
    expect(r.reason).toContain("artifact_readiness");
  });

  test("execution != code → отказ", () => {
    const r = planGate(validPlan.replace("execution: code", "execution: knowledge-work"), "branch");
    expect(r.ok).toBe(false);
  });

  test("нет frontmatter → отказ", () => {
    const r = planGate("# just a doc\n", "branch");
    expect(r.ok).toBe(false);
  });

  test("--until=pr → явный отказ «не реализовано»", () => {
    const r = planGate(validPlan, "pr");
    expect(r.ok).toBe(false);
    if (r.ok) throw new Error("expected refusal");
    expect(r.reason).toContain("pr");
  });
});

describe("docReviewGate", () => {
  test("оба конверта ok → green", () => {
    const r = docReviewGate({ claudeStatus: "ok", opencodeStatus: "ok" });
    expect(r.state).toBe("green");
  });

  test("один конверт failed → green (advisory) с причиной", () => {
    const r = docReviewGate({ claudeStatus: "ok", opencodeStatus: "failed" });
    expect(r.state).toBe("green");
    expect(r.reasons.join(" ")).toContain("opencode");
  });

  test("оба конверта failed → degraded, не failed и не green", () => {
    const r = docReviewGate({ claudeStatus: "failed", opencodeStatus: "failed" });
    expect(r.state).toBe("degraded");
  });

  test("стадия без вывода (crash/timeout) → failed", () => {
    const r = docReviewGate(undefined);
    expect(r.state).toBe("failed");
  });

  const sev = (p0: number, p1: number, max = p0 ? "P0" : p1 ? "P1" : "NONE") => ({ maxSeverity: max, p0Count: p0, p1Count: p1 });

  test("R3/R4: один leg p0=1, другой p0=0 → failed (max-of-legs, fail-closed)", () => {
    const r = docReviewGate({ claudeStatus: "ok", opencodeStatus: "ok", claudeSeverity: sev(1, 0), opencodeSeverity: sev(0, 2) });
    expect(r.state).toBe("failed");
    expect(r.cause).toBe("severity");
    expect(r.reasons.join(" ")).toContain("claude reports 1 P0");
  });

  test("оба leg сообщают P0 → failed, причины называют оба leg", () => {
    const r = docReviewGate({ claudeStatus: "ok", opencodeStatus: "ok", claudeSeverity: sev(2, 0), opencodeSeverity: sev(1, 0) });
    expect(r.state).toBe("failed");
    const reasons = r.reasons.join(" ");
    expect(reasons).toContain("claude reports 2 P0");
    expect(reasons).toContain("opencode reports 1 P0");
  });

  test("только P1 → green, p1Count = сумма по leg, без блокировки", () => {
    const r = docReviewGate({ claudeStatus: "ok", opencodeStatus: "ok", claudeSeverity: sev(0, 3), opencodeSeverity: sev(0, 4) });
    expect(r.state).toBe("green");
    expect(r.p1Count).toBe(7);
    expect(r.cause).toBeUndefined();
  });

  test("R5: оба ok, оба severity отсутствуют → green (сегодняшнее поведение) + advisory", () => {
    const r = docReviewGate({ claudeStatus: "ok", opencodeStatus: "ok" });
    expect(r.state).toBe("green");
    expect(r.reasons.join(" ")).toContain("severity summary missing");
  });

  test("один leg упал (нет конверта), выживший leg P0 → failed", () => {
    const r = docReviewGate({ claudeStatus: "failed", opencodeStatus: "ok", opencodeSeverity: sev(1, 0) });
    expect(r.state).toBe("failed");
    expect(r.cause).toBe("severity");
    expect(r.reasons.join(" ")).toContain("opencode reports 1 P0");
  });

  test("один leg упал, у выжившего severity отсутствует → green с двумя advisory-причинами", () => {
    const r = docReviewGate({ claudeStatus: "failed", opencodeStatus: "ok" });
    expect(r.state).toBe("green");
    const reasons = r.reasons.join(" ");
    expect(reasons).toContain("claude envelope missing");
    expect(reasons).toContain("opencode severity summary missing");
  });

  test("оба leg упали → degraded, severity игнорируется (существующее поведение)", () => {
    const r = docReviewGate({ claudeStatus: "failed", opencodeStatus: "failed", claudeSeverity: sev(9, 9), opencodeSeverity: sev(9, 9) });
    expect(r.state).toBe("degraded");
    expect(r.cause).toBe("availability");
  });

  test("cause-маркеры: no-output и both-down → availability", () => {
    expect(docReviewGate(undefined).cause).toBe("availability");
    expect(docReviewGate({ claudeStatus: "failed", opencodeStatus: "failed" }).cause).toBe("availability");
  });
});

describe("workGate (KTD3, KTD14 tree-hash proof)", () => {
  const baseTree = "a".repeat(40);
  const headTree = "b".repeat(40);

  test("валидный конверт + tree изменился + validate-cmd 0 → green", () => {
    const r = workGate({ raw: workEnvelope(), baseTree, headTree, validateExitCode: 0 });
    expect(r.state).toBe("green");
  });

  test("verification_evidence пустое → failed с причиной", () => {
    const r = workGate({ raw: workEnvelope({ verification_evidence: [] }), baseTree, headTree, validateExitCode: 0 });
    expect(r.state).toBe("failed");
    expect(r.reasons.join(" ")).toContain("verification_evidence");
  });

  test("tree головы == base (нет изменений контента) → failed", () => {
    const r = workGate({ raw: workEnvelope(), baseTree, headTree: baseTree, validateExitCode: 0 });
    expect(r.state).toBe("failed");
    expect(r.reasons.join(" ")).toContain("tree hash");
  });

  test("jj-clean-tree обман не проходит: конверт complete, но tree не изменился → failed", () => {
    const r = workGate({ raw: workEnvelope({ final_commit_sha: "c".repeat(40) }), baseTree, headTree: baseTree, validateExitCode: 0 });
    expect(r.state).toBe("failed");
  });

  test("final_commit_sha теперь advisory: расходится с деревом, но tree изменён → green", () => {
    const r = workGate({ raw: workEnvelope({ final_commit_sha: "d".repeat(40) }), baseTree, headTree, validateExitCode: 0 });
    expect(r.state).toBe("green");
  });

  test("status != complete → failed", () => {
    const r = workGate({ raw: workEnvelope({ status: "blocked" }), baseTree, headTree, validateExitCode: 0 });
    expect(r.state).toBe("failed");
  });

  test("validate-cmd exit != 0 → failed", () => {
    const r = workGate({ raw: workEnvelope(), baseTree, headTree, validateExitCode: 2 });
    expect(r.state).toBe("failed");
    expect(r.reasons.join(" ")).toContain("validate");
  });

  test("validate-cmd не запускалась → failed, не green", () => {
    const r = workGate({ raw: workEnvelope(), baseTree, headTree, validateExitCode: null });
    expect(r.state).toBe("failed");
  });

  test("конверт-мусор (не парсится) → degraded, не failed и не green", () => {
    const r = workGate({ raw: "{truncated", baseTree, headTree, validateExitCode: 0 });
    expect(r.state).toBe("degraded");
  });

  test("стадия без конверта → failed (сразу Approval per KTD5)", () => {
    const r = workGate({ raw: undefined, baseTree, headTree, validateExitCode: null });
    expect(r.state).toBe("failed");
  });

  test("exit 127 из-за отсутствующего раннера назван как отсутствующий раннер, а не как упавший тест", () => {
    // #given ровно тот вывод, который закрыл gate-work на run-1786717826270
    const output = "$ vitest run --config scripts/vitest.config.ts\n/bin/bash: vitest: command not found\n";

    // #when
    const r = workGate({ raw: workEnvelope(), baseTree, headTree, validateExitCode: 127, validateOutput: output });

    // #then причина называет бинарь и путь к починке
    expect(r.state).toBe("failed");
    const reason = r.reasons.join(" ");
    expect(reason).toContain('"vitest" is not installed');
    expect(reason).toContain("--setup-cmd");
  });

  test("exit 0 при нулевом покрытии → гейт остаётся green, advisory лишь приписан (issue 018)", () => {
    // #given вывод сегмента, который не нашёл ни одного файла, и exit 0
    const output = "Found 0 warnings and 0 errors.\nFinished in 4ms on 0 files with 96 rules using 18 threads.\n";

    // #when
    const r = workGate({ raw: workEnvelope(), baseTree, headTree, validateExitCode: 0, validateOutput: output });

    // #then зелёный остаётся зелёным
    expect(r.state).toBe("green");
  });

  test("гейт красный по другой причине + exit 0 при нулевом покрытии → state остаётся failed", () => {
    // #given конверт без evidence и validate-cmd, ничего не проверивший
    const output = "No test files found, exiting with code 0\n";

    // #when
    const r = workGate({ raw: workEnvelope({ verification_evidence: [] }), baseTree, headTree, validateExitCode: 0, validateOutput: output });

    // #then advisory не меняет вердикт, посчитанный до него
    expect(r.state).toBe("failed");
  });

  test("нормальный green без вывода validate-cmd → причин нет", () => {
    // #when / #then граничный вход: вывод не захвачен
    expect(workGate({ raw: workEnvelope(), baseTree, headTree, validateExitCode: 0 }).reasons).toEqual([]);
  });
});

// Каждый фрагмент — реальный вывод инструмента, снятый 2026-08-15 на пути,
// который не совпал ни с одним файлом (см. docs/issues/2026-08-14-018).
const EMPTY_COVERAGE_FIXTURES: Array<{ tool: string; output: string; line: string }> = [
  { tool: "oxfmt", output: "\nNo files found matching the given patterns.\nFinished in 0ms on 0 files using 18 threads.\n", line: "No files found matching the given patterns." },
  { tool: "oxlint ≤1.50", output: "Found 0 warnings and 0 errors.\nFinished in 4ms on 0 files with 96 rules using 18 threads.\n", line: "Finished in 4ms on 0 files with 96 rules using 18 threads." },
  { tool: "oxlint ≥1.60", output: "No files found to lint. Please check your paths and ignore patterns.\n", line: "No files found to lint. Please check your paths and ignore patterns." },
  { tool: "vitest", output: " RUN  v4.1.10 /tmp/vi\n\nNo test files found, exiting with code 0\n\nfilter:  scripts/\n", line: "No test files found, exiting with code 0" },
  { tool: "ruff", output: "warning: No Python files found under the given path(s)\nAll checks passed!\n", line: "warning: No Python files found under the given path(s)" },
  { tool: "pytest", output: "collected 0 items\n\n============================ no tests ran in 0.00s =============================\n", line: "collected 0 items" },
  { tool: "bun test", output: "bun test v1.3.14 (0d9b296a)\nerror: 0 test files matching **{.test,.spec}.{js,ts} in --cwd=\"/tmp/notests\"\n", line: 'error: 0 test files matching **{.test,.spec}.{js,ts} in --cwd="/tmp/notests"' },
  { tool: "jest", output: "No tests found, exiting with code 0\n", line: "No tests found, exiting with code 0" },
  { tool: "tsc", output: "error TS18003: No inputs were found in config file '/tmp/tsconfig.json'. Specified 'include' paths were '[\"src/**/*.ts\"]'.\n", line: "error TS18003: No inputs were found in config file '/tmp/tsconfig.json'. Specified 'include' paths were '[\"src/**/*.ts\"]'." },
  { tool: "eslint", output: "\nESLint: 10.8.1\n\nNo files matching the pattern \"scripts/**/*.ts\" were found.\nPlease check for typing mistakes in the pattern.\n", line: 'No files matching the pattern "scripts/**/*.ts" were found.' },
  { tool: "prettier", output: "Checking formatting...\n[error] No supported files were found in the directory: \"scripts/\".\nAll matched files use Prettier code style!\n", line: '[error] No supported files were found in the directory: "scripts/".' },
  // biome красит вывод: ANSI-последовательности снимаются, фраза остаётся
  { tool: "biome", output: "\u001B[0m  \u001B[1m\u001B[34mℹ\u001B[0m \u001B[34mThese paths were provided but ignored:\u001B[0m\n  - scripts/\n", line: "ℹ These paths were provided but ignored:" },
];

describe("emptyCoverageSignals (пустое покрытие validate-cmd, issue 018)", () => {
  for (const fixture of EMPTY_COVERAGE_FIXTURES) {
    test(`${fixture.tool}: вывод про ноль файлов распознан и строка сохранена дословно`, () => {
      // #given реальный вывод инструмента, наведённого на путь вне его скоупа
      const output = fixture.output;

      // #when
      const signals = emptyCoverageSignals(output);

      // #then совпавшая строка возвращается целиком, а не просто флаг
      expect(signals.map((s) => s.line)).toContain(fixture.line);
    });
  }

  test("нормальный успешный прогон (файлы были) → сигналов нет", () => {
    // #given oxlint и vitest, которые реально что-то проверили
    const output = "Found 0 warnings and 0 errors.\nFinished in 62ms on 41 files with 96 rules using 18 threads.\n Test Files  32 passed (32)\n      Tests  517 passed (517)\n";

    // #when
    const signals = emptyCoverageSignals(output);

    // #then
    expect(signals).toEqual([]);
  });

  test("вывода нет (undefined) → сигналов нет", () => {
    // #when / #then граничный вход: validate-cmd без захваченного вывода
    expect(emptyCoverageSignals(undefined)).toEqual([]);
  });

  test("пустой вывод → сигналов нет", () => {
    // #when / #then
    expect(emptyCoverageSignals("")).toEqual([]);
  });

  test("одна и та же строка на каждый пакет монорепо → один сигнал, не N", () => {
    // #given цикл по 4 пакетам, каждый печатает одно и то же
    const output = Array.from({ length: 4 }, () => "No files found matching the given patterns.").join("\n");

    // #when
    const signals = emptyCoverageSignals(output);

    // #then
    expect(signals).toHaveLength(1);
  });

  test("много разных пустых строк → не больше 5 сигналов (причина уходит в колонку вердикта)", () => {
    // #given шесть разных инструментов подряд
    const output = EMPTY_COVERAGE_FIXTURES.map((f) => f.output).join("\n");

    // #when
    const signals = emptyCoverageSignals(output);

    // #then
    expect(signals).toHaveLength(5);
  });

  test("очень длинная строка обрезается", () => {
    // #given строка с совпадением и хвостом на 400 символов
    const output = `No files found matching the given patterns. ${"x".repeat(400)}`;

    // #when
    const signals = emptyCoverageSignals(output);

    // #then
    expect(signals[0].line).toHaveLength(161);
  });
});

describe("emptyCoverageReason (advisory, не блокирующий)", () => {
  test("exit != 0 → advisory не добавляется (прогон и так красный и получает хвост вывода)", () => {
    // #given тот же вывод, но команда упала
    const output = "No files found matching the given patterns.\n";

    // #when
    const reason = emptyCoverageReason(1, output);

    // #then
    expect(reason).toBeUndefined();
  });

  test("validate-cmd не запускалась (null) → advisory не добавляется", () => {
    // #when / #then граничный вход
    expect(emptyCoverageReason(null, "No files found matching the given patterns.")).toBeUndefined();
  });

  test("exit 0 и нормальный вывод → причины нет", () => {
    // #when / #then
    expect(emptyCoverageReason(0, "Finished in 62ms on 41 files with 96 rules using 18 threads.")).toBeUndefined();
  });

  test("точка с запятой внутри строки инструмента не разрывает причину при склейке через \"; \"", () => {
    // #given инструмент напечатал точку с запятой в своей строке
    const output = 'No files found matching the given patterns; check the config\n';

    // #when причина склеивается в колонку вердикта ровно как в toVerdict
    const joined = ["envelope status is \"blocked\"", emptyCoverageReason(0, output) ?? ""].join("; ");

    // #then advisory восстанавливается целиком
    expect(emptyCoverageNotes(joined)[0]).toContain("check the config");
  });
});

describe("emptyCoverageNotes (перенос advisory в summary)", () => {
  test("вердикт с advisory → нота извлечена", () => {
    // #given причины, склеенные так же, как их пишет toVerdict
    const joined = ["worktree tree hash equals base", emptyCoverageReason(0, "No test files found, exiting with code 0") ?? ""].join("; ");

    // #when
    const notes = emptyCoverageNotes(joined);

    // #then
    expect(notes).toHaveLength(1);
  });

  test("строка вердикта без advisory → нот нет", () => {
    // #when / #then
    expect(emptyCoverageNotes("validate-cmd exited with code 1")).toEqual([]);
  });

  test("строка вердикта пустая (зелёный гейт до этого изменения) → нот нет, резюме не падает", () => {
    // #when / #then граничный вход: строка из БД, записанная до появления advisory
    expect(emptyCoverageNotes("")).toEqual([]);
  });

  test("вердикта нет (undefined) → нот нет", () => {
    // #when / #then
    expect(emptyCoverageNotes(undefined)).toEqual([]);
  });
});

describe("mainCheckoutEscapeReason (побег из воркитри, run-1786717826270)", () => {
  const baseTree = "a".repeat(40);
  const headTree = "b".repeat(40);

  test("digest не менялся → причины нет", () => {
    expect(mainCheckoutEscapeReason("/abs/repo", "same", "same")).toBeUndefined();
  });

  test("резюм со старой строки staging (digest отсутствует) → причины нет, не падаем", () => {
    // #given строка staging, записанная до появления поля
    expect(mainCheckoutEscapeReason("/abs/repo", undefined, "digest-now")).toBeUndefined();
    expect(mainCheckoutEscapeReason("/abs/repo", null, "digest-now")).toBeUndefined();
  });

  test("digest изменился → причина названа и указывает оператору на checkout", () => {
    // #when
    const reason = mainCheckoutEscapeReason("/abs/repo", "at-staging", "now");

    // #then сообщение само ведёт к диагнозу: где смотреть и какой командой
    expect(reason).toContain("/abs/repo");
    expect(reason).toContain("git -C /abs/repo status");
    expect(reason).toContain("OUTSIDE its worktree");
  });

  test("appendEscapeAdvisory: диагноз advisory — зелёный work-гейт остаётся зелёным", () => {
    // #given зелёный work-гейт
    const verdict = workGate({ raw: workEnvelope(), baseTree, headTree, validateExitCode: 0 });
    expect(verdict.state).toBe("green");
    const reasonCount = verdict.reasons.length;

    // #when продакшен-композиция se-pipeline workGateFn дописывает диагноз
    const result = appendEscapeAdvisory(verdict, "/abs/repo", "at-staging", "now");

    // #then причина дописана, но состояние не тронуто — ложный позитив не
    // стоит лишнего work-плеча
    expect(result.reasons).toHaveLength(reasonCount + 1);
    expect(result.reasons[reasonCount]).toContain("/abs/repo");
    expect(result.state).toBe("green");
  });

  test("appendEscapeAdvisory: на красном KTD14-вердикте диагноз стоит рядом с симптомом", () => {
    // #given work-гейт закрылся по «нет изменений контента»
    const verdict = workGate({ raw: workEnvelope(), baseTree, headTree: baseTree, validateExitCode: 0 });
    const reasonCount = verdict.reasons.length;

    // #when
    const result = appendEscapeAdvisory(verdict, "/abs/repo", "at-staging", "now");

    // #then оператор видит и симптом (KTD14), и настоящую причину
    expect(result.state).toBe("failed");
    expect(result.reasons).toHaveLength(reasonCount + 1);
    expect(result.reasons[reasonCount]).toContain("git -C /abs/repo status");
  });

  test("appendEscapeAdvisory: без побега вердикт не трогается", () => {
    // #given
    const verdict = workGate({ raw: workEnvelope(), baseTree, headTree, validateExitCode: 0 });
    const reasonCount = verdict.reasons.length;

    // #when digest не менялся
    const result = appendEscapeAdvisory(verdict, "/abs/repo", "same", "same");

    // #then ни причины, ни состояния — advisory-контракт держится и на
    // пути без побега
    expect(result.reasons).toHaveLength(reasonCount);
    expect(result.state).toBe("green");
  });
});

describe("codeReviewGate", () => {
  test("P0=0 при 12×P1 → green с p1Count=12", () => {
    const r = codeReviewGate({ raw: reviewReport(0, 12) });
    expect(r.state).toBe("green");
    expect(r.p1Count).toBe(12);
  });

  test("P0>0 → failed с числом находок", () => {
    const r = codeReviewGate({ raw: reviewReport(2, 1) });
    expect(r.state).toBe("failed");
    expect(r.reasons.join(" ")).toContain("2");
  });

  test("конверт-мусор → degraded", () => {
    const r = codeReviewGate({ raw: "not json at all" });
    expect(r.state).toBe("degraded");
  });

  test("валидный JSON без findings → degraded (невалидный конверт, не тихий pass)", () => {
    const r = codeReviewGate({ raw: JSON.stringify({ status: "complete" }) });
    expect(r.state).toBe("degraded");
  });

  test("стадия без вывода → failed", () => {
    const r = codeReviewGate({ raw: undefined });
    expect(r.state).toBe("failed");
  });

  const legReport = (legs: Record<string, string>, p0: number, p1: number): string => {
    const findings = [
      ...Array.from({ length: p0 }, (_, i) => ({ severity: "P0", title: `p0-${i}` })),
      ...Array.from({ length: p1 }, (_, i) => ({ severity: "P1", title: `p1-${i}` })),
    ];
    return JSON.stringify({ status: "complete", findings, legs });
  };

  test("один leg упал, выживший без P0 → degraded (не тихий single-leg pass, F2/KTD-C)", () => {
    // #given a merged report where the claude leg failed and opencode is clean
    const r = codeReviewGate({ raw: legReport({ claude: "failed", opencode: "ok" }, 0, 3) });
    // #then the clean survivor is not trusted alone — human ack required
    expect(r.state).toBe("degraded");
    expect(r.reasons.join(" ")).toContain("claude");
    expect(r.p1Count).toBe(3);
  });

  test("один leg упал, но выживший нашёл P0 → failed (блокировка важнее живости лега)", () => {
    // #given a failed leg but a P0 on the surviving leg
    const r = codeReviewGate({ raw: legReport({ claude: "failed", opencode: "ok" }, 1, 0) });
    // #then blocking wins regardless of leg health, and the dead leg is noted
    expect(r.state).toBe("failed");
    expect(r.reasons.join(" ")).toContain("claude");
  });

  test("оба lega ok, P0=0 → green (обе стороны отревьюили)", () => {
    const r = codeReviewGate({ raw: legReport({ claude: "ok", opencode: "ok" }, 0, 2) });
    expect(r.state).toBe("green");
    expect(r.p1Count).toBe(2);
  });

  test("все lega упали → degraded (не тихий pass)", () => {
    const r = codeReviewGate({ raw: legReport({ claude: "failed", opencode: "failed" }, 0, 0) });
    expect(r.state).toBe("degraded");
    expect(r.reasons.join(" ")).toContain("all review legs failed");
  });
});

describe("rescanGate (пост-approval пересканирование, R3/R4/R5)", () => {
  const rescanReport = (overrides: Record<string, unknown> = {}): string =>
    JSON.stringify({ moved: true, scan: { state: "clean", details: "" }, validateExitCode: 0, scannedHead: "a".repeat(40), currentHead: "b".repeat(40), ...overrides });

  test("HEAD не двигался → green без причин (AE3)", () => {
    const r = rescanGate({ raw: JSON.stringify({ moved: false, scannedHead: "a".repeat(40), currentHead: "a".repeat(40) }) });
    expect(r.state).toBe("green");
    expect(r.reasons).toEqual([]);
  });

  test("двигался, скан чист, validate 0 → green с информационной причиной", () => {
    const r = rescanGate({ raw: rescanReport() });
    expect(r.state).toBe("green");
    expect(r.reasons.length).toBe(1);
    expect(r.reasons.join(" ")).toContain("bbbbbbbb");
  });

  test("двигался, скан found → degraded с усечённым details (AE1)", () => {
    const r = rescanGate({ raw: rescanReport({ scan: { state: "found", details: "AKIA-redacted-leak" } }) });
    expect(r.state).toBe("degraded");
    expect(r.reasons.join(" ")).toContain("AKIA-redacted-leak");
  });

  test("двигался, скан error → degraded (краш сканера — никогда не pass)", () => {
    const r = rescanGate({ raw: rescanReport({ scan: { state: "error", details: "gitleaks missing" } }) });
    expect(r.state).toBe("degraded");
  });

  test("двигался, validate exit 3 → failed с кодом в причине (AE2)", () => {
    const r = rescanGate({ raw: rescanReport({ validateExitCode: 3 }) });
    expect(r.state).toBe("failed");
    expect(r.reasons.join(" ")).toContain("3");
  });

  test("двигался, validateExitCode null (не запускалась) → failed (KTD3)", () => {
    const r = rescanGate({ raw: rescanReport({ validateExitCode: null }) });
    expect(r.state).toBe("failed");
  });

  test("raw undefined → failed", () => {
    const r = rescanGate({ raw: undefined });
    expect(r.state).toBe("failed");
  });

  test("невалидный JSON → failed (нет результата ≠ pass)", () => {
    const r = rescanGate({ raw: "{truncated" });
    expect(r.state).toBe("failed");
  });
});
