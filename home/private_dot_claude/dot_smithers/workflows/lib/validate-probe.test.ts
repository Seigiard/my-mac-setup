import { describe, expect, test } from "bun:test";
import { commandHeads, missingRunnerMessage, probeValidateCmd, segmentHead, selfProvisioning, shellQuote, splitSegments } from "./validate-probe.ts";

const resolvesAll = (): boolean => true;
const resolvesNone = (): boolean => false;
const resolvesOnly =
  (...available: string[]) =>
  (head: string): boolean =>
    available.includes(head);

describe("splitSegments", () => {
  test("разделяет по &&, ||, ;, | и переводу строки", () => {
    expect(splitSegments("a && b || c ; d | e\nf")).toEqual(["a", "b", "c", "d", "e", "f"]);
  });

  test("скобки подоболочки — тоже граница: форма, которую собирает lib/plan.ts", () => {
    expect(splitSegments("(bun test) && (tsc)")).toEqual(["bun test", "tsc"]);
  });

  test("оператор внутри кавычек границей не считается", () => {
    // #given `&&` живёт внутри аргумента, а не разделяет команды
    const segments = splitSegments("bun test --filter 'a && b'");

    // #then одна команда, а не две
    expect(segments).toEqual(["bun test --filter 'a && b'"]);
  });
});

describe("segmentHead", () => {
  test("берёт первое слово команды", () => {
    expect(segmentHead("vitest run --config scripts/vitest.config.ts")).toBe("vitest");
  });

  test("ведущие присваивания переменных пропускаются", () => {
    expect(segmentHead("CI=1 NODE_ENV=test bun test")).toBe("bun");
  });

  test("путь как голова команды сохраняется", () => {
    expect(segmentHead("./scripts/check.sh --strict")).toBe("./scripts/check.sh");
  });

  test("динамическая голова не читается статически → null", () => {
    // #given подстановка переменной вместо имени бинаря
    expect(segmentHead("$RUNNER test")).toBe(null);
    expect(segmentHead("`which tsc` --noEmit")).toBe(null);
  });

  test("пустой сегмент → null", () => {
    expect(segmentHead("   ")).toBe(null);
  });
});

describe("commandHeads", () => {
  test("собирает головы всех сегментов без повторов", () => {
    expect(commandHeads("(bun test) && (tsc) && (bun run lint)")).toEqual(["bun", "tsc"]);
  });
});

describe("selfProvisioning", () => {
  test("команда с install создаёт свой раннер сама", () => {
    expect(selfProvisioning("bun install && vitest run")).toBe(true);
  });

  test("make считается провижинингом", () => {
    expect(selfProvisioning("make setup")).toBe(true);
  });

  test("чистая проверка ничего не устанавливает", () => {
    expect(selfProvisioning("vitest run --config scripts/vitest.config.ts")).toBe(false);
  });
});

describe("probeValidateCmd", () => {
  test("отсутствующий раннер найден до work-этапа — случай run-1786717826270", () => {
    // #given ровно та команда, которая упала с exit 127 на живом прогоне
    const cmd = "vitest run --config scripts/vitest.config.ts";

    // #when в свежем worktree нет node_modules/.bin
    const report = probeValidateCmd(cmd, resolvesNone);

    // #then
    expect(report.missing).toEqual(["vitest"]);
    expect(report.skipped).toBe(false);
  });

  test("установленный раннер претензий не вызывает", () => {
    expect(probeValidateCmd("bun test", resolvesAll).missing).toEqual([]);
  });

  test("самопровиженящаяся команда не судится вовсе — ложный отказ дороже пропуска", () => {
    // #given раннера ещё нет, но `bun install` его поставит
    const report = probeValidateCmd("bun install && vitest run", resolvesNone);

    // #then
    expect(report).toEqual({ probed: [], missing: [], skipped: true });
  });

  test("из составной команды называется только отсутствующая половина", () => {
    const report = probeValidateCmd("(bun test) && (vitest run)", resolvesOnly("bun"));
    expect(report.missing).toEqual(["vitest"]);
    expect(report.probed).toEqual(["bun", "vitest"]);
  });
});

describe("missingRunnerMessage", () => {
  test("называет бинарь, причину и оба выхода", () => {
    const msg = missingRunnerMessage("vitest run", ["vitest"]);
    expect(msg).toContain('"vitest"');
    expect(msg).toContain("--setup-cmd");
    expect(msg).toContain("--validate-cmd");
    expect(msg).toContain("vitest run");
  });
});

describe("shellQuote", () => {
  test("одинарная кавычка внутри слова не разрывает цитирование", () => {
    expect(shellQuote("it's")).toBe(`'it'\\''s'`);
  });
});
