import { describe, expect, test } from "bun:test";

import { deriveValidateCmd, extractValidateCmd } from "./plan.ts";

// A contract whose only content is the given commands, one per fenced line.
const contractWith = (...cmds: string[]): string => `## Verification Contract\n\n\`\`\`bash\n${cmds.join("\n")}\n\`\`\`\n`;

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

// Every line of the reproduction table in
// docs/issues/2026-08-14-010-validate-cmd-filter-is-unsound-in-both-directions.md.
describe("deriveValidateCmd: раннер решает, а не строка целиком (issue 010)", () => {
  test("настоящий lint-гейт остаётся, хотя раннер называется `oxlint`, а не `lint`", () => {
    // #given команда, которую старый фильтр отбрасывал: `oxlint` — не токен `lint`
    const md = contractWith("oxlint --deny-warnings src/a.ts");

    // #when
    const derived = deriveValidateCmd(md);

    // #then
    expect(derived.cmd).toBe("(oxlint --deny-warnings src/a.ts)");
  });

  test("тот же гейт с test-именем файла держится на раннере, а не на имени файла", () => {
    // #given раньше эта строка выживала только из-за `test` в имени файла
    const withTestFile = deriveValidateCmd(contractWith("oxlint --deny-warnings src/a.test.ts"));
    const withoutTestFile = deriveValidateCmd(contractWith("oxlint --deny-warnings src/a.ts"));

    // #when / #then решение одинаковое — имя файла в него не входит
    expect(withTestFile.cmd).toBe("(oxlint --deny-warnings src/a.test.ts)");
    expect(withoutTestFile.cmd).not.toBeNull();
  });

  test("путь `tests/fixtures/…` больше не сталкивается с forbid-подстрокой `fix`", () => {
    // #given собственные фикстуры этого репозитория лежат в tests/fixtures
    const md = contractWith("bun test tests/fixtures/plan.test.ts");

    // #when
    const derived = deriveValidateCmd(md);

    // #then
    expect(derived.cmd).toBe("(bun test tests/fixtures/plan.test.ts)");
  });

  test("значение флага (`--grep fixture`) не участвует в решении", () => {
    expect(extractValidateCmd(contractWith("npm run test:unit -- --grep fixture"))).toBe("(npm run test:unit -- --grep fixture)");
  });

  test("мутирующий флаг `--write` отклоняет команду и попадает в dropped с причиной", () => {
    // #given форматтер в гейте пачкает worktree, и work-gate падает не по делу
    const md = contractWith("oxfmt --write src/a.test.ts");

    // #when
    const derived = deriveValidateCmd(md);

    // #then
    expect(derived.cmd).toBeNull();
    expect(derived.dropped).toEqual([
      { cmd: "oxfmt --write src/a.test.ts", reason: "refused: segment `oxfmt --write src/a.test.ts` carries the mutating flag `--write`" },
    ]);
  });

  test("мутирующий флаг бьёт read-only флаг в том же сегменте", () => {
    // #given `--check` рядом с `--write` ничего не спасает: файлы всё равно переписываются
    const derived = deriveValidateCmd(contractWith("oxfmt --write --check tests"));

    // #when / #then
    expect(derived.cmd).toBeNull();
    expect(derived.dropped[0].reason).toContain("mutating flag `--write`");
  });

  test("`biome check --write` отклоняется, несмотря на подкоманду `check`", () => {
    const derived = deriveValidateCmd(contractWith("biome check --write src/a.test.ts"));
    expect(derived.cmd).toBeNull();
    expect(derived.dropped[0].reason).toContain("mutating flag `--write`");
  });

  test("составная строка судится посегментно: мутирующая вторая половина топит всю команду", () => {
    // #given первая половина — настоящий гейт, вторая переписывает src
    const derived = deriveValidateCmd(contractWith("bun test && oxfmt --write src"));

    // #when / #then причина называет именно виноватый сегмент
    expect(derived.cmd).toBeNull();
    expect(derived.dropped[0].reason).toBe("refused: segment `oxfmt --write src` carries the mutating flag `--write`");
  });

  test("правильные команды остаются правильными (bun test, tsc --noEmit, cd + bun test)", () => {
    expect(extractValidateCmd(contractWith("bun test"))).toBe("(bun test)");
    expect(extractValidateCmd(contractWith("tsc --noEmit"))).toBe("(tsc --noEmit)");
    // `cd <pkg> && …` — намеренная форма, её ломать нельзя
    expect(extractValidateCmd(contractWith("cd pkg && bun test"))).toBe("(cd pkg && bun test)");
  });

  test("неизвестный раннер не отбрасывается молча — команда остаётся, а note её называет", () => {
    // #given ровно так чуть не исчез lint-гейт: незнакомое имя = тихий drop
    const derived = deriveValidateCmd(contractWith("frobnicate --strict src"));

    // #when / #then
    expect(derived.cmd).toBe("(frobnicate --strict src)");
    expect(derived.notes).toHaveLength(1);
    expect(derived.notes[0]).toContain("`frobnicate`");
  });

  test("отброшенная команда всегда объяснена: storybook-строка называет свой раннер", () => {
    const derived = deriveValidateCmd(contractWith("bun run storybook"));
    expect(derived.cmd).toBeNull();
    expect(derived.dropped[0].reason).toContain("server/watch/e2e runner");
  });

  test("форматтер с read-only флагом — настоящий гейт", () => {
    // #given `prettier --check` ничего не переписывает
    expect(extractValidateCmd(contractWith("prettier --check ."))).toBe("(prettier --check .)");
    // #then а он же без флага — переписывает
    expect(extractValidateCmd(contractWith("prettier ."))).toBeNull();
  });

  test("флаги-отрицания и префиксные формы не читаются как мутирующие", () => {
    // #given `--no-fix` и `--fix-dry-run` совпадают с `--fix` только по префиксу
    expect(extractValidateCmd(contractWith("eslint --no-fix src"))).toBe("(eslint --no-fix src)");
    expect(extractValidateCmd(contractWith("eslint --fix-dry-run src"))).toBe("(eslint --fix-dry-run src)");
    // #then а настоящий `--fix` отдельным аргументом — отклоняется
    expect(extractValidateCmd(contractWith("eslint --fix src"))).toBeNull();
  });

  test("`-w` у workspace-фронтенда — селектор пакета, а не in-place запись", () => {
    // #given npm -w <pkg> run test: `-w` съедает следующее слово до имени скрипта
    expect(extractValidateCmd(contractWith("npm -w pkg run test"))).toBe("(npm -w pkg run test)");
    // #then после раннера тот же `-w` считается мутирующим
    expect(extractValidateCmd(contractWith("oxfmt -w src"))).toBeNull();
  });

  test("extractValidateCmd — тонкая обёртка: тот же cmd, что у deriveValidateCmd", () => {
    const md = contractWith("bun test", "oxfmt --write src");
    expect(extractValidateCmd(md)).toBe(deriveValidateCmd(md).cmd);
    expect(deriveValidateCmd(md).dropped).toHaveLength(1);
  });
});

// A plan that DECLARES its commands instead of being parsed for them
// (docs/issues/2026-08-14-014-plan-format-contract.md).
const declaring = (...cmds: string[]): string =>
  ["---", "artifact_readiness: implementation-ready", "validate_commands:", ...cmds.map((c) => `  - ${c}`), "---", "", "# Plan", ""].join("\n");

describe("deriveValidateCmd: декларация в frontmatter (issue 014)", () => {
  test("декларированный список исполняется дословно и помечен как declared", () => {
    // #given план сам называет свои команды
    const md = declaring("bun run test:unit", "cd pkg && bun run typecheck");

    // #when
    const derived = deriveValidateCmd(md);

    // #then порядок и текст сохранены, источник — декларация
    expect(derived).toMatchObject({ cmd: "(bun run test:unit) && (cd pkg && bun run typecheck)", source: "declared" });
  });

  test("keep-фильтр к декларации не применяется: незнакомый раннер исполняется без notes", () => {
    // #given раннер, которого фильтр не знает, — но оператор его выписал
    const derived = deriveValidateCmd(declaring("frobnicate --strict src"));

    // #when / #then команда идёт как есть, и это больше не наблюдение
    expect(derived.cmd).toBe("(frobnicate --strict src)");
    expect(derived.notes).toEqual([]);
  });

  test("команда, которую парсер выбросил бы как не-верификацию, в декларации остаётся", () => {
    // #given `bun run build` — распознанный НЕ-верификационный раннер
    const declared = deriveValidateCmd(declaring("bun run build"));
    const parsed = deriveValidateCmd(contractWith("bun run build"));

    // #when / #then прозе — отказ, декларации — исполнение
    expect(parsed.cmd).toBeNull();
    expect(declared.cmd).toBe("(bun run build)");
  });

  test("мутирующий флаг отклоняет весь запуск и называет флаг с причиной", () => {
    // #given форматтер в гейте пачкает worktree — work-гейт упадёт не по делу
    const derived = deriveValidateCmd(declaring("bun run test:unit", "oxfmt --write src"));

    // #when / #then соседняя валидная команда запуск не спасает
    expect(derived.cmd).toBeNull();
    expect(derived.dropped).toEqual([
      {
        cmd: "oxfmt --write src",
        reason: "refused: segment `oxfmt --write src` carries the mutating flag `--write` — the work gate runs the validate-cmd and then requires a clean worktree, so a command that rewrites files fails the stage for a reason unrelated to the work",
      },
    ]);
  });

  test("мутирующий флаг ловится в любом сегменте составной команды", () => {
    const derived = deriveValidateCmd(declaring("bun test && oxfmt --write src"));
    expect(derived.dropped[0].reason).toContain("segment `oxfmt --write src` carries the mutating flag `--write`");
  });

  test("имя, похожее на мутирующее, декларацию не отклоняет — отклоняет только флаг", () => {
    // #given `fmt:check` распадается на `fmt` + `check`; в прозе это отказ по имени
    const declared = deriveValidateCmd(declaring("bun run fmt:check"));

    // #when / #then догадка по имени не имеет права блокировать выписанную команду
    expect(declared.cmd).toBe("(bun run fmt:check)");
  });

  test("декларация побеждает секцию Verification Contract", () => {
    // #given в плане есть и то, и другое, и они не совпадают
    const md = `${declaring("bun run test:unit")}\n## Verification Contract\n\n- Run \`bun run test:e2e-ish\` too.\n`;

    // #when
    const derived = deriveValidateCmd(md);

    // #then выигрывает то, что автор написал явно, а не то, что вычитала эвристика
    expect(derived.cmd).toBe("(bun run test:unit)");
  });

  test("сломанная декларация не откатывается к секции — она отказывает", () => {
    // #given опечатка в декларации при живой секции Verification Contract
    const md = `---\nvalidate_commands: bun test\n---\n\n## Verification Contract\n\n- Run \`bun run test:unit\`.\n`;

    // #when
    const derived = deriveValidateCmd(md);

    // #then иначе прогон исполнил бы не то, что объявлено, и молча
    expect(derived.cmd).toBeNull();
    expect(derived.dropped[0].reason).toContain("is not a block list");
  });

  test("план без ключа читается парсером ровно как раньше", () => {
    // #given сегодняшний план из целевого репозитория — миграции нет
    const derived = deriveValidateCmd(planWithContract);

    // #when / #then
    expect(derived.source).toBe("parsed");
    expect(derived.cmd).toBe(extractValidateCmd(planWithContract));
  });

  test("скалярное значение вместо списка отклонено с указанием, как писать", () => {
    const derived = deriveValidateCmd("---\nvalidate_commands: bun test\n---\n");
    expect(derived.dropped).toEqual([
      { cmd: "validate_commands:", reason: "`validate_commands: bun test` is not a block list — write one command per `- ` line under the key." },
    ]);
  });

  test("flow-список (`[a, b]`) отклонён — запятая внутри команды его бы разорвала", () => {
    const derived = deriveValidateCmd("---\nvalidate_commands: [bun test, tsc]\n---\n");
    expect(derived.dropped[0].reason).toContain("is not a block list");
  });

  test("ключ без единой команды отклонён с подсказкой про fallback", () => {
    // #given ключ есть, список пуст — следующий ключ идёт сразу за ним
    const derived = deriveValidateCmd("---\nvalidate_commands:\nartifact_readiness: implementation-ready\n---\n\n## Verification Contract\n\n- `bun test`\n");

    // #when / #then
    expect(derived.cmd).toBeNull();
    expect(derived.dropped[0].reason).toBe(
      "validate_commands is present but lists no command — declare at least one, or drop the key to fall back to the Verification Contract section.",
    );
  });

  test("пустая запись в списке отклонена с её номером", () => {
    const derived = deriveValidateCmd(declaring("bun test", '""'));
    expect(derived.dropped[0].reason).toBe("entry 2 of validate_commands is empty — every entry must be a command the work gate can run.");
  });

  test("маркер `-` без значения — тоже пустая запись", () => {
    const derived = deriveValidateCmd("---\nvalidate_commands:\n  -\n  - bun test\n---\n");
    expect(derived.dropped[0].reason).toContain("entry 1 of validate_commands is empty");
  });

  test("кавычки снимаются, YAML-комментарий у неквотированной записи отрезается", () => {
    // #given квотированная команда несёт `#` внутри себя, неквотированная — комментарий
    const derived = deriveValidateCmd(declaring('"bun test --grep \'a # b\'"', "bun run typecheck # быстрый гейт"));

    // #when / #then
    expect(derived.cmd).toBe("(bun test --grep 'a # b') && (bun run typecheck)");
  });

  test("комментарии и пустые строки внутри списка пропускаются", () => {
    const md = "---\nvalidate_commands:\n  # самый узкий гейт\n  - bun test\n\n  - tsc --noEmit\nexecution: code\n---\n";
    expect(deriveValidateCmd(md).cmd).toBe("(bun test) && (tsc --noEmit)");
  });

  test("`-` без пробела записью не считается — это не YAML-список", () => {
    // #given опечатка, которую и настоящий YAML-парсер записью не прочитает
    const derived = deriveValidateCmd("---\nvalidate_commands:\n  -bun test\n---\n");

    // #when / #then отказ, а не молчаливое чтение сломанного файла
    expect(derived.dropped[0].reason).toContain("lists no command");
  });

  test("комментарий после самого ключа списку не мешает", () => {
    const md = "---\nvalidate_commands: # узкий гейт по затронутым пакетам\n  - bun test\n---\n";
    expect(deriveValidateCmd(md).cmd).toBe("(bun test)");
  });

  test("extractValidateCmd видит декларацию тем же значением", () => {
    const md = declaring("bun test");
    expect(extractValidateCmd(md)).toBe("(bun test)");
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
