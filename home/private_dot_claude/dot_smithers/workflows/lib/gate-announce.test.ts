import { describe, expect, test } from "bun:test";
import { gateAnnouncement } from "./gate-announce.ts";

describe("gateAnnouncement", () => {
  test("зелёный гейт — одна строка, без рамки и без вопроса к оператору", () => {
    expect(gateAnnouncement("work", "green", "", null)).toBe("GATE work: GREEN");
  });

  test("красный гейт называет состояние словом, а не галочкой", () => {
    // #given вердикт gate-work из run-1786718288581
    const out = gateAnnouncement("work", "failed", "validate-cmd exited with code 1", "extra-attempt");

    // #then
    expect(out).toContain("GATE work: FAILED");
  });

  test("причина печатается — именно её на живом прогоне не увидел никто", () => {
    const out = gateAnnouncement("work", "failed", "validate-cmd exited with code 1", "extra-attempt");
    expect(out).toContain("why: validate-cmd exited with code 1");
  });

  test("approve на упавшем гейте назван повтором стадии, а не продолжением", () => {
    // #given ровно та ловушка: оператор прочитал approve как «продолжай»
    const out = gateAnnouncement("work", "failed", "boom", "extra-attempt");

    // #then
    expect(out).toContain("ONE more attempt");
    expect(out).toContain("deny = abort the run");
  });

  test("waive-гейт говорит, что approve пропускает проверку и продолжает", () => {
    const out = gateAnnouncement("verify-doc", "failed", "P0", "waive");
    expect(out).toContain("WAIVE");
    expect(out).toContain("CONTINUE");
  });

  test("вторая неудача — approve останавливает прогон, а не продолжает его", () => {
    const out = gateAnnouncement("work", "failed", "boom", "abort-only");
    expect(out).toContain("STOP the run");
  });

  test("многострочный хвост остаётся продолжением своей причины, а не новыми why", () => {
    // #given причины склеены "; ", а хвост validate-cmd сам многострочный
    const reasons = "validate-cmd exited with code 1; validate-cmd output tail: FAIL result.test.ts\nCannot find module sdk/dist/index.node.js";

    // #when
    const lines = gateAnnouncement("work", "failed", reasons, "extra-attempt").split("\n");

    // #then две причины помечены why, хвост идёт с отступом продолжения
    expect(lines.filter((l) => l.startsWith("  why: "))).toHaveLength(2);
    expect(lines).toContain("       Cannot find module sdk/dist/index.node.js");
  });

  test("пустая причина не выдаётся за отсутствие проблемы", () => {
    const out = gateAnnouncement("work", "failed", "", "extra-attempt");
    expect(out).toContain("no reason recorded");
  });

  test("degraded не превращается в failed и не теряет рамку", () => {
    const out = gateAnnouncement("verify-code", "degraded", "envelope unreadable", "waive");
    expect(out).toContain("GATE verify-code: DEGRADED");
  });
});
