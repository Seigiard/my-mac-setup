import { describe, expect, test } from "bun:test";

import { extractValidateCmd } from "./plan.ts";

// Mirrors the real ce-unified-plan/v1 Verification Contract shape (PRD-2099).
const planWithContract = `---
artifact_readiness: implementation-ready
---

# Plan

## Verification Contract

| Gate | Command | Covers |
|---|---|---|
| Engine unit tests | \`cd engine/api && timeout 120 bun run test routines\` (touched files) | U1-U4 |
| Engine pglite | \`cd engine/api && timeout 120 bun run test:db:pglite routines.postgres.test.ts\` | U2 |
| Console unit tests | \`cd console && timeout 60 bunx vitest run --project=unit RoutineTriggerSection\` | U6 |
| Stories render | \`bun run storybook\`; VRT baselines | U5 |
| Typecheck | \`cd engine/api && bun run typecheck\`; \`cd sdk && bun run typecheck\` | schema |
| Contracts | \`bun run fix\`, then \`bun run contracts:check:api\` | API delta |
| Manual | agent actually choosing cron is verified manually with one live build | AE4 |

## Definition of Done
`;

describe("extractValidateCmd", () => {
  test("derives runnable check/test commands from the Verification Contract, each in its own subshell", () => {
    const cmd = extractValidateCmd(planWithContract);
    if (cmd === null) throw new Error("expected a derived command");
    // kept: scoped tests + typechecks + the check half of the contracts row
    expect(cmd).toContain("bun run test routines");
    expect(cmd).toContain("test:db:pglite");
    expect(cmd).toContain("vitest run --project=unit");
    expect(cmd).toContain("bun run typecheck");
    expect(cmd).toContain("contracts:check:api");
    // each command isolated so a `cd` doesn't leak into the next
    expect(cmd).toContain("&&");
    expect(cmd.trim().startsWith("(")).toBe(true);
  });

  test("skips server/watch/e2e/VRT and mutating commands", () => {
    const cmd = extractValidateCmd(planWithContract) ?? "";
    expect(cmd).not.toContain("storybook");
    expect(cmd).not.toContain("bun run fix"); // mutates the worktree
    expect(cmd).not.toContain("live build");
  });

  test("no Verification Contract section → null", () => {
    expect(extractValidateCmd("# Plan\n\n## Definition of Done\n")).toBeNull();
  });

  test("contract present but no runnable commands → null", () => {
    const md = `## Verification Contract\n\n| Gate | Command | Covers |\n|---|---|---|\n| Manual | verified by hand | AE1 |\n| Visual | \`bun run storybook\` | U1 |\n`;
    expect(extractValidateCmd(md)).toBeNull();
  });

  test("skips watch-mode runners (bare vitest / --watch)", () => {
    const md = `## Verification Contract\n\n| Gate | Command | Covers |\n|---|---|---|\n| Watch | \`vitest --watch\` | U1 |\n| Unit | \`bun run test:unit\` | U2 |\n`;
    const cmd = extractValidateCmd(md) ?? "";
    expect(cmd).not.toContain("--watch");
    expect(cmd).toContain("test:unit");
  });
});

describe("extractValidateCmd: не-командные спаны (регрессия run-1784823010502)", () => {
  test("голый `test` из прозаической аннотации отбрасывается", () => {
    // #given реальная строка платформенного плана: аннотация "(script is `e2e`, not `test`)"
    const md = [
      "## Verification Contract",
      "",
      "| Check | Command | Applies to |",
      "|---|---|---|",
      "| Page specs | `cd e2e && bun run e2e` (engine running; script is `e2e`, not `test`) | U2-U6 |",
      "| Typecheck | `cd console && bun run typecheck` | U5 |",
    ].join("\n");

    // #when
    const cmd = extractValidateCmd(md) ?? "";

    // #then голое слово `test` — не команда (shell builtin, всегда exit 1)
    expect(cmd).not.toContain("(test)");
    expect(cmd).toContain("bun run typecheck");
  });

  test("keep-сигнал внутри имени файла (withTests) не делает jq-строку верификацией", () => {
    // #given coverage-строка: jq по манифесту, "test" только как подстрока имени поля
    const md = [
      "## Verification Contract",
      "",
      "| Check | Command | Applies to |",
      "|---|---|---|",
      "| Coverage | `jq '.coverage.withTests' contracts/ux/ux-manifest.json` | U7 |",
      "| Unit | `bun run test:unit` | U2 |",
    ].join("\n");

    // #when
    const cmd = extractValidateCmd(md) ?? "";

    // #then jq-строка отброшена, настоящая test-строка осталась
    expect(cmd).not.toContain("jq");
    expect(cmd).toContain("test:unit");
  });

  test("одиночный standalone-раннер (tsc, pytest) остаётся командой", () => {
    const md = "## Verification Contract\n\n| Gate | Command |\n|---|---|\n| Types | `tsc` |\n| Py | `pytest` |\n";
    expect(extractValidateCmd(md)).toBe("(tsc) && (pytest)");
  });
});

describe("extractValidateCmd: fenced-блоки", () => {
  test("команды из ```bash-блока извлекаются как из таблицы", () => {
    // #given Verification Contract с fenced-блоком (формат ce-plan)
    const md = [
      "## Verification Contract",
      "",
      "From the repo root:",
      "",
      "```bash",
      "cd pkg && bun install --frozen-lockfile && bun test",
      "cd pkg && bun build entry.tsx --target=bun --outfile=/tmp/x.js # transpile check",
      "```",
      "",
      "Both must exit 0.",
      "",
      "## Definition of Done",
    ].join("\n");

    // #when
    const cmd = extractValidateCmd(md);

    // #then извлечена test-строка; build-строка без keep-сигнала отброшена
    expect(cmd).toBe("(cd pkg && bun install --frozen-lockfile && bun test)");
  });

  test("watch/e2e строки в fenced-блоке отбрасываются, пустой блок → null", () => {
    const md = "## Verification Contract\n```bash\nbun test --watch\nplaywright test e2e/\n```\n";
    expect(extractValidateCmd(md)).toBe(null);
  });

  test("не-bash блок (```json) игнорируется", () => {
    const md = '## Verification Contract\n```json\n{"test": true}\n```\n';
    expect(extractValidateCmd(md)).toBe(null);
  });
});

describe("extractValidateCmd: списки", () => {
  test("bullet-пункт с инлайновой командой в бэктиках извлекается", () => {
    // #given contract написан списком — третья форма в дикой природе
    const md = "## Verification Contract\n\n- Run `bun run test:scripts` before merging.\n";

    // #when
    const cmd = extractValidateCmd(md);

    // #then
    expect(cmd).toBe("(bun run test:scripts)");
  });

  test("нумерованный и звёздочный маркеры читаются так же", () => {
    const md = "## Verification Contract\n\n1. `bun test`\n2) `tsc`\n* `bun run lint`\n+ `pytest`\n";
    expect(extractValidateCmd(md)).toBe("(bun test) && (tsc) && (bun run lint) && (pytest)");
  });

  test("голый параграф командой не считается — прозаический `test` не отравляет гейт", () => {
    // #given формулировка, которая испортила гейт run-1784823010502
    const md = "## Verification Contract\n\nThe script is `e2e`, not `test`.\n";

    // #when
    const cmd = extractValidateCmd(md);

    // #then параграф не источник команд
    expect(cmd).toBe(null);
  });

  test("тот же прозаический текст внутри списка тоже не даёт команды", () => {
    // #given список читается, но фильтр раннеров всё ещё работает
    const md = "## Verification Contract\n\n- The script is `e2e`, not `test`.\n";
    expect(extractValidateCmd(md)).toBe(null);
  });

  test("`--flag` в бэктиках не путается с маркером списка", () => {
    const md = "## Verification Contract\n\n--watch is forbidden; use `bun test`.\n";
    expect(extractValidateCmd(md)).toBe(null);
  });
});

describe("extractValidateCmd (contract heading nested below H2)", () => {
  test("finds an H3 contract and stops at the next H3 sibling — Sources globs never read as commands", () => {
    // #given the shape that killed a real gate-0: the contract nested under
    // Planning Contract, with a sibling section whose fenced glob line
    // carries a `test` token
    const md = [
      "# Plan",
      "",
      "## Planning Contract",
      "",
      "### Verification Contract",
      "",
      "| Gate | Command | Covers |",
      "|---|---|---|",
      "| Unit | `bun run test:unit` | U1 |",
      "",
      "### Sources",
      "",
      "```",
      "include: ['**/*.test.ts', '**/*.test.tsx']",
      "```",
      "",
    ].join("\n");

    expect(extractValidateCmd(md)).toBe("(bun run test:unit)");
  });

  test("H3 contract is also terminated by a following H2 heading", () => {
    const md = [
      "## Planning Contract",
      "",
      "### Verification Contract",
      "",
      "| Gate | Command |",
      "|---|---|",
      "| Types | `bun run typecheck` |",
      "",
      "## Appendix",
      "",
      "| Note | `vitest run --project=unit not-a-gate` |",
      "",
    ].join("\n");

    expect(extractValidateCmd(md)).toBe("(bun run typecheck)");
  });
});
