# se-pipeline — раннбук

Durable-прогон `verify-doc → work → verify-code` над целевым репозиторием на
Smithers 0.32.0 (без локальных патчей; detached-логи в `.smithers/logs/` с
ретеншном). План: `docs/plans/2026-07-14-001-feat-smithers-pipeline-plan.md`
(gitignored). Исходники: `home/private_dot_claude/dot_smithers/` (chezmoi →
`~/.claude/.smithers`); состояние прогонов (`smithers.db`, `.smithers/`) живёт в
рантайм-дире и в git не попадает.

Модели плеч запинены константами в `se-pipeline.tsx`: work —
`claude-opus-4-8` (fallback `claude-sonnet-5`), review — `claude-sonnet-5`
(fallback `claude-haiku-4-5`); донор doc-review (`se-doc-review.tsx`) —
`claude-sonnet-5`/`claude-haiku-4-5`.

Verify-code повторяет форму se-code-review: два независимых
полных plugin-ревью параллельно — claude (`claude-sonnet-5`, кап 25 мин) +
opencode (`openai/gpt-5.5`, кап 15 мин, скилл стейджится в
`/tmp/ce-code-review`, разрешён в opencode `permission.external_directory`) —
и детерминированное слияние (`lib/review-merge.ts`) на nodeId стадии: гейт
считает P0 по объединённым findings (каждый тегирован `source`): любое P0 →
`failed` (блокировка важнее живости плеча), оба плеча упали → `degraded`. Одно
упавшее плечо при чистом выжившем (0 P0) → `degraded`, НЕ тихий single-leg green:
мёртвое плечо (например, healthy claude, убитый по `PROCESS_IDLE_TIMEOUT`) могло
нести единственный P0, поэтому гейт паузит на человеческий ack вместо прохода по
выжившему. Без ретрая — ретрай переоткрывает budget-инцидент (KTD-C); прогон
паузит, не перебиливает. Это расходится с docReviewGate (там одно упавшее плечо
остаётся advisory-green — doc-review нонблокинг для work; verify-code — последний
гейт перед branch/PR, fail-closed жёстче). Пер-плечевые отчёты пишутся в reportDir
(`verify-code.claude.report.json` / `verify-code.opencode.report.json`) рядом со слитым.

Verify-doc блокирует по P0 находкам ревью плана (симметрия с
codeReviewGate). Каждое не-smoke плечо эмитит машиночитаемую строку
`SEVERITY: {"maxSeverity":"P0|P1|P2|none","p0Count":N,"p1Count":N}` в защищённом
слоте — последняя непустая строка прямо перед финальным `Review complete`;
парсер (`lib/severity-summary.ts`) читает ТОЛЬКО этот слот (декой `SEVERITY:` в
теле конверта инертен), при отсутствии/невалидном JSON/отрицательных счётчиках →
`undefined`. Envelope-контракт (`≥500` симв., последняя строка `Review complete`,
`SMOKE OK`-байпас) не тронут — severity-слой никогда не влияет на валидность
конверта. Гейт: любое доступное плечо с `p0Count > 0` → `failed` (max-of-legs,
fail-closed — один P0 блокирует, даже если второе плечо 0); P1 — advisory
(суммируется, не блокирует); отсутствие severity деградирует ЭТО плечо к
поведению «только доступность» (R5). Слоение толерантности (KTD-D): доступность
плеч остаётся fail-closed (нет вывода → `failed`, оба плеча вниз → `degraded`),
а severity-слой лишь ДОБАВЛЯЕТ блокирующую силу — его отсутствие никогда не
ослабляет гейт ниже чистой доступности. Пер-плечевой статус парса severity
(parsed/missing) пишется в notes и `verify-doc.result.json` каждый прогон —
системный отказ контракта виден, а не тихо инертен. SEVERITY-строка выстригается
из конверта перед инъекцией в work-промпт (`readDocReviewAdvisory`) и из синтеза
standalone-скилла — это вход гейта, не контент ревью.

## Стадия simplify и два входа (se-work / se-review-and-work)

У пайплайна два именованных входа над ОДНИМ `se-pipeline.tsx` и
одним внутренним ключом `docReview` (пользователь его не печатает — вход выбирает
команда):

- **`se-work`** — `docReview:false`: `work → simplify → verify-code → branch/PR`,
  БЕЗ plan-review. Для уже подготовленного, отревьюенного человеком плана.
- **`se-review-and-work`** — `docReview:true`: то же плюс `verify-doc` впереди
  (`verify-doc → work → simplify → verify-code`). CLI: `se pipeline … --doc-review`.

Стадия `verify-doc` условная (рендерится только при `docReview:true`); при
`false` `work` привязан прямо к gate-0, и в summary `verify-doc` = `null`.

**Simplify — постоянная стадия в ОБЕИХ командах**, не флаг. Вставлена ПОСЛЕ
общего secret-scan (её внешние отчётные ноги видят только уже прочищенный
сканом контент — KTD10) и ПЕРЕД verify-code (ревью идёт по уже прибранному коду).
Это `Subflow` над `se-simplify.tsx` (тот же приём, что `se-doc-review.tsx`), с
`repoPath: staged.worktreePath` — ИЗОЛИРОВАННЫЙ worktree прогона, никогда не
launch-checkout оператора (KTD-G). Вход `preScanned: true` выключает
собственный pre-external-гейт субфлоу: диапазон уже покрыт общим secret-scan,
включая операторский waive, и повторный отказ отменил бы решение человека.
Standalone-запуск `se-simplify` этот вход не передаёт — гейт там работает.

Форма `se-simplify.tsx` (общий модуль, он же standalone-скилл `se-simplify`):
right-sizing gate (R14) → заморозка снапшота → `Parallel` двух ОТЧЁТНЫХ ног
(claude `claude-sonnet-5`, opencode `openai/gpt-5.5`), гоняющих ревьюеров
`ce-simplify-code` (Steps 1-2, не применяя ничего; скилл стейджится в
`/tmp/ce-simplify`, разрешён в opencode `permission.external_directory`) →
`mergeSimplifyLegs` (`lib/review-merge.ts`): consensus (обе ноги, совпало по
файл+строка±3+сходство `suggested_change`) / unique (одна нога) в apply-набор,
**contradiction** (одно место, расходящиеся правки) — advisory, ИСКЛЮЧЕНА из
apply → ОДНА apply-нога (`claude-sonnet-5`, `permissionMode: acceptEdits`,
re-locate по контенту т.к. батч сдвигает строки, denylist: креды / `op://`
шаблоны / `dot_zshenv*` / permission/shell-init) → verify через validate-cmd.
Фейл verify или ноль выживших ног → **revert всего apply + `degraded`**, никогда
тихий success. Одна выжившая нога → её находки как unique (usable), без
cross-model консенсуса. `smoke:true` — синтетика без реального `ce-simplify-code`.

Заморозка снапшота (и в se-simplify, и в стейджинге se-code-review/verify-code)
идёт через `stashCreateSafe` (`lib/staging.ts`): `git update-index -q --refresh`
перед `git stash create`, плюс страховка «тихий exit 1 без вывода = нечего
стешить» — голый `stash create` на stat-dirty дереве (validate-cmd переписал
tracked-файл байт-в-байт, индекс не освежён) молча выходит с кодом 1.
Диагностический признак такого отказа в `_smithers_attempts`: у ноды `stage`
error_json c `status: 1` и пустыми stdout/stderr.

Right-sizing gate (`lib/stage-gate.ts`, R14) решает run/skip БЕЗ флага, смещение
**skip-when-unsure** (обратное review-стадиям — неверный run авто-мутирует
малоценный код, неверный skip лишь оставляет неприбранным): пустой / doc-only /
generated / vendored / lockfile / binary дифф → skip; ≥20 строк исполняемого кода
→ run; между — `inconclusive`, отдаётся дешёвому Haiku-классификатору (тоже
skip-when-unsure). `skipped` рапортуется с причиной, не тихий проход.

Коммит и рескан simplify — **pipeline-owned и условные** (`simplifyCommitDecision`):
только `ok`-с-правками коммитится (`commitWorkGuarded`, «se-pipeline: simplify
stage on <branch>») и потом пере-сканируется (`simplify-rescan`, диапазон
work-HEAD..simplify-commit) перед внешними ногами verify-code — т.к. simplify идёт
ПОСЛЕ первого secret-scan, его коммит ещё не покрыт (R9). `skipped` / `degraded` /
`ok`-без-правок → нет коммита, нет рескана, verify-code идёт по work-коммиту.
Пост-approval рескан после verify-code берёт scannedHead из simplify-rescan (если
был), чтобы не пере-валидировать simplify-коммит каждый прогон.

Модели simplify запинены в `lib/agents.ts`: `simplifyReview` (`claude-sonnet-5` /
fallback `claude-haiku-4-5`, размер как docReview) для отчётных ног,
`SIMPLIFY_APPLY_MODEL` = `claude-sonnet-5` для apply (не Opus — apply исполняет уже
решённые находки под guard'ом сохранения поведения, KTD-F), классификатор —
`claude-haiku-4-5`. Standalone `se-simplify` ТРЕБУЕТ явный `validate-cmd` (вне
пайплайна нет gate-0 / Verification Contract), иначе отказывается применять.

## Секретный барьер: два яруса

Внешние ноги получают ПОЛНЫЙ чекаут снапшот-коммита и читают в нём любой
отслеживаемый файл, а не только то, что тронул прогон. Поэтому барьер двухъярусный
(`lib/pre-external-gate.ts`), и оба яруса стоят до создания снапшот-worktree:

- **Ярус 1 — диапазон** (`preExternalRepoGate` / `secretScanDiff` в стадии
  `secret-scan`): `base..snapshot`, вопрос «добавил ли секрет ЭТОТ прогон».
- **Ярус 2 — дерево** (`preExternalTreeGate`): всё дерево на снапшот-коммите, то
  есть ровно то, что уедет наружу. Секрет, закоммиченный в базовую ветку ДО
  прогона, виден только здесь. Дерево выгружается `git archive` во временный
  каталог (не сканируем живой worktree: после `setupCmd` в нём лежат
  `node_modules` и билд-артефакты — это не содержимое репозитория), сканируется
  и удаляется — в том числе на пути отказа.

Ярус 2 судит находки против **per-repo baseline**, иначе он бы блокировал каждый
прогон: `gitleaks dir` по рабочему каталогу этого репо даёт 48 находок, по
отслеживаемому дереву HEAD — 3, и все три фикстуры (`configs/MTMR/items.json`,
`workflows/lib/issue-writer.test.ts`, `workflows/lib/block-effects.test.ts`).

Baseline живёт **рядом с состоянием харнесса, никогда внутри целевого репо**:
`~/.claude/.smithers/state/secret-baseline/<basename>-<12 hex от sha256 абсолютного
пути репо>.json`. Ключ — репозиторий, а не worktree (`git rev-parse
--git-common-dir`): иначе каждый прогон в своём `.worktrees/<run>` снимал бы
свежий baseline и тем самым авто-одобрял любую находку.

Поведение:

- baseline нет → снимается с текущего скана, прогон ПРОХОДИТ, в лог уходит
  громкая заметка: сколько находок забаселайнено, абсолютный путь файла и что всё
  внутри него невидимо для будущих прогонов, пока оператор его не почистит.
- baseline есть → отказ только по находкам, которых в нём НЕТ; отказ называет их
  fingerprint'ы (`путь:правило:строка`, без секрета).
- сканер не запустился / дерево не выгрузилось → отказ (fail-closed), как в ярусе 1.
- `SE_SKIP_SECRET_SCAN=1` пропускает ярус 2 так же, как ярус 1.

В пайплайне ярус 2 не бросает исключение, а едет в тот же `gateFn` стадии
`secret-scan`: находка → degraded → уже существующая Approval с waive-семантикой.

**Действия оператора с baseline** (харнесс сам их не делает):

```bash
# посмотреть, что забаселайнено для репо
ls ~/.claude/.smithers/state/secret-baseline/
python3 -c "import json,sys;[print(f['Fingerprint']) for f in json.load(open(sys.argv[1]))]" \
  ~/.claude/.smithers/state/secret-baseline/<repo>-<digest>.json

# вычистить одну запись (реальный секрет, а не фикстура) — правь JSON руками,
# удаляя её объект из массива; следующий прогон по ней откажет

# пере-снять baseline с нуля (после чистки репо от секретов)
rm ~/.claude/.smithers/state/secret-baseline/<repo>-<digest>.json
# следующий прогон снимет заново и скажет об этом в логе
```

## Дев-цикл, доставка и апгрейд

Правки воркфлоу делаются в source-дире рабочего репо
(`home/private_dot_claude/dot_smithers/`): там же `bun install`, `bun test`
(state — `node_modules`, `smithers.db` — gitignored). Доставка в рантайм:
commit → push → `chezmoi git pull` → `chezmoi apply ~/.claude/.smithers` →
**пофайловая сверка** (`diff -r <source>/workflows ~/.claude/.smithers/workflows`)
— `chezmoi diff` по КАТАЛОГУ может вернуть ложную пустоту при реальном дрейфе,
сверять только пофайлово или прямым diff. Правка исходников между запуском и
resume ломает resume без `--accept-workflow-change` — доставлять при нуле
in-flight прогонов.

Апгрейд smithers-orchestrator (всегда на последнюю версию):

1. Ноль in-flight прогонов (`se list`).
2. Бамп в `package.json` source-дира → `bun install` → `bun test` →
   `bunx smithers-orchestrator graph` на каждый workflow (грузится ли новым
   движком).
3. Commit/push → доставка как выше → `bun install` в `~/.claude/.smithers` →
   `bunx smithers-orchestrator --version`.
4. Smoke на фикстуре (`make-pipeline-fixture.sh`, `smoke:true`), затем полный
   фикстурный прогон с реальными агентами.
5. Секцию «Smithers-причуды» сверить с релиз-нотами и первым реальным
   прогоном; обновить под текущую версию.

## Запуск

Из целевого репозитория (cwd = репо):

```bash
se pipeline docs/plans/<план>.md --validate-cmd 'bun test'                 # se-work: без plan-review, с simplify
se pipeline docs/plans/<план>.md --validate-cmd 'bun test' --doc-review    # se-review-and-work: + verify-doc впереди
```

- План обязан быть `ce-unified-plan/v1` с `artifact_readiness: implementation-ready`
  и `execution: code` — иначе gate-0 роняет прогон с причиной (AE4).
- `--validate-cmd` обязателен: пайплайн никогда не читает команды из конфига
  целевого репо (KTD8). Гейт work-стадии исполняет её в worktree сам.
- `--setup-cmd '<cmd>'` — опциональный провижининг worktree (установка
  зависимостей, билд workspace-dists, нужных validate-cmd); см. пункт про
  built dists в разделе validate-cmd.
- По умолчанию detached: печатает `runId` и возвращается; прогон переживает
  закрытие терминала. `--attach` стримит логи в foreground; **Ctrl-C на attached
  = SIGINT = отмена прогона** (smithers аккуратно abort'ит), не detach. Чтобы
  оставить прогон жить и перестать смотреть — не используй `--attach` (detached
  дефолт) и следи через `se logs <runId>`; отменённый прогон восстанавливается
  `se resume <runId>`.
- `--until=branch` (дефолт) — стоп на локальной закоммиченной ветке
  `se/<план>-<runid8>`. `--until=pr` пока не реализован (явный отказ).
- `--doc-review` — включить стадию verify-doc (plan-review) впереди. По умолчанию
  выключено (`se-work`); скилл `se-review-and-work` его передаёт. Simplify в флаг
  НЕ входит — всегда присутствует и авто-run/skip. Пользователь выбирает командой,
  не флагом.

## Динамическая композиция флоу (`se flow`)

`se pipeline` — фиксированный порядок стадий. `se flow` — единый вход
динамической композиции: оркестратор классифицирует задачу, собирает **флоу-спек**
(декларативные данные, не код) из библиотеки типизированных блоков и запускает его
через один статический интерпретатор `workflows/se-flow.tsx`. Файл интерпретатора
не меняется между прогонами — варьируется только спек на входе (R7/KTD1), поэтому
`workflowHash` стабилен и resume работает для любого собранного флоу. Шесть ручных
`se-*` скиллов остаются рабочими без изменений (KD6).

```bash
se blocks --json                                    # каталог блоков, из которого композируется спек (KTD6)
se flow spec.json --budget 25 --setup-cmd 'make setup'   # запуск собранного спека
se flow spec.json --dry-run                         # печать input JSON + команды без запуска
```

- Спек — операторские данные. Командные поля несут **референс источника**
  (`flag:`/`plan:`/`ref:`/`{ref}`), не инлайн-строку команды (KTD15).
- Валидатор (`workflows/lib/flow-validate.ts`) проверяет спек до запуска и на
  gate-0: грамматика id и запрет зарезервированных аффиксов, DAG по `after`,
  достижимость `bindTo` через `after`-предков, совместимость границ по
  идентичности схемы (KTD14), `secret-scan` перед каждым `external`-блоком
  (R6/AE1), обязательные `retries`/`timeoutMs`, провенанс команд, наличие
  архива `artifactsFrom`. Отказ — машиночитаемый `{invariant, blockId|edge, hint}`.
- `--budget N` — потолок стоимости прогона: превышение **паркует** прогон под
  ack оператора, никогда не убивает (KTD9).
- Флоу без workspace-нужных блоков (research, doc-review) не берёт лок и не
  стейджит worktree — условие считает интерпретатор по флагам каталога, спеком
  оно не выражается (KTD2).

Форма спека (директивно):

```text
flowSpec {
  task: { description, classification }
  repo, setupCmdRef?, budgetUsd?, artifactsFrom?
  blocks: [ { id, block: <имя из каталога>, input, retries, timeoutMs,
              after: [id...], bindTo: [id...], waive: none|approval } ]
}
```

Каталог блоков v1: `secret-scan`, `rescan`, `commit-work`, `run-validate`,
`proof-artifacts`, `pr` (compute); `work`, `repro`, `analysis`, `subtasks`
(agent); `code-review`, `simplify`, `doc-review` (subflow с mirror-ключом
KTD3). `code-review`/`doc-review` — `external: true` и требуют `secret-scan`
среди `after`-предков. Терминальный ревьюер и outcome-record — эпилог
интерпретатора (KTD2/KTD10), не блоки спека.

## validate-cmd: по умолчанию из плана

work-гейт гоняет validate-cmd **синхронно с таймаутом** (дефолт 600 с,
`--validate-timeout N` секунд), чтобы доказать работу агента (self-report не
ground truth, KTD3).

**По умолчанию команда извлекается из секции `Verification Contract` самого
плана** (канонично `## `-заголовок; вложенный `###`–`######` тоже принимается —
секция читается до заголовка того же или более высокого уровня, поэтому
вложенный контракт не поглощает соседние секции)
(gate-0) — `/se-plan` уже кладёт туда узкие, с таймаутами команды. Ничего
передавать не нужно:
```bash
se pipeline docs/plans/<план>.md          # validate берётся из плана
```
Команды читаются из трёх форм: строк markdown-таблицы, fenced-блоков
(```` ```bash ````) и пунктов списка (`-`/`*`/`+`/`1.`) с инлайновыми
бэктиками. Голый параграф источником команд не считается намеренно: проза несёт
бэктиковые идентификаторы, и один реальный прогон отравил гейт, выведя `(test)`
из фразы «script is `e2e`, not `test`».

Пайплайн печатает выбранную команду в лог (`work-gate validate-cmd [plan
Verification Contract]: ...`). Извлекаются только исполнимые check/test/typecheck
строки; **отбрасываются** `storybook`/`--watch`/e2e/playwright (сервер/браузер) и
`fix`/`format` (мутируют worktree → уронили бы clean-tree-проверку). Ручные/VRT
строки игнорируются. Если в плане нет исполнимых команд — gate-0 роняет прогон с
просьбой добавить их или передать `--validate-cmd`.

`--validate-cmd '<cmd>'` — **только override** (или для legacy-планов без
Verification Contract). KTD8: из плана (доверенный вход) извлекать безопасно; из
конфига целевого репо — по-прежнему нельзя (чужой коммит исполнил бы произвольное).

Если пишешь Verification Contract сам или override — команда должна быть
**быстрой, узкой, самодостаточной**:

- **`bun test` ≠ `bun run test`.** `bun test` — встроенный раннер bun,
  рекурсивно берёт ВСЕ `*.test/*.spec` (включая e2e/playwright) → таймаут.
  Нужен проектный скрипт: `bun run test`, `npm test`, `pnpm test`, `make test`.
- **Скоупь по затронутой области, не по корню.** Смотри `Files:` юнитов плана
  / где легли коммиты work. Монорепа: фильтруй пакет
  (`turbo run test --filter=<pkg>`, `nx test <pkg>`, `pnpm --filter <pkg> test`).
- **Unit/type, не e2e.** Годится: `tsc --noEmit`, `<runner> --project=unit`,
  vitest с in-memory БД (pglite и т.п.). Не годится для гейта: playwright/`e2e/`,
  тесты с реальной БД/сетью/браузером — worktree прогона это чистый checkout от
  committed HEAD, сервисов там нет.
- **Проверь руками до запуска.** Прогони кандидата в репо, засеки. >2–3 мин или
  нужен dev-сервер/БД/сеть → не подходит.
- **Worktree прогона не содержит built dists workspace-пакетов.** Тест,
  импортирующий `dist/` соседнего пакета, упадёт на «Cannot find module» в
  чистом worktree, хотя в рабочем checkout зелёный. Для такого validate-cmd
  передавай провижининг: `--setup-cmd 'bun install && bunx turbo run build
  --filter=<pkg>'` — команда оператора (KTD8-доверенная, как validate-cmd),
  исполняется один раз в staged worktree до work; ненулевой exit роняет
  прогон до трат на агентов. Таймаут — input `setupTimeoutMs` (дефолт 15 мин).
- **Команда проверяется до work-этапа, в две ступени.** Нода `probe` сразу после
  setup сначала резолвит головные слова validate-cmd (`command -v` в staged
  worktree, тем же login-шеллом, что и сам validate-cmd): не нашёлся бинарь —
  отказ за миллисекунды с именем бинаря. Команда, которая ставит зависимости
  сама (`bun install && …`, `make …`), эту ступень пропускает — раннер появится
  по ходу, и ложный отказ дороже пропуска.

  Затем `probe` **исполняет validate-cmd один раз на базовом коммите**, до
  отправки агента. Красный базовый прогон сам по себе не ошибка: план, который
  чинит падающий тест, обязан стартовать с красного. Отказ идёт только на
  отказе ОКРУЖЕНИЯ — `Cannot find module`, `No module named`, `command not
  found`: свежий worktree не содержит собранных workspace-dists, и никакая
  работа агента этого не исправит. Всё остальное классифицируется как
  `assertion`, печатается в лог и пропускается дальше. Цена — один лишний прогон
  validate-cmd (ещё одна причина держать его быстрым); экономия — оплаченный
  work-этап, как на `run-1786718288581`, где та же ошибка окружения была
  оплачена дважды.
- **Флак validate — почти всегда гонка в suite целевого репо, не движок.**
  Наблюдавшийся класс: один тест создаёт/удаляет файл-фикстуру в дереве
  репо, а параллельный ratchet-чекер обходит файлы и крашится на ENOENT —
  падает то и дело в любом окружении. Прежде чем винить движок, прогони ту
  же команду циклом из шелла (`for i in 1 2 3 4; do <cmd>; done`) — флак
  проявится и там. Известно-флакующие suites в validate-cmd не включать.
- **Комбинируй дёшево:** `tsc --noEmit && <узкий unit-скрипт>`.
- **Таймаут — страховка, не решение.** `--validate-timeout` поднимает потолок,
  но синхронный длинный прогон блокирует heartbeat движка (spawnSync) — правильно
  сузить команду.

Пример (монорепа, план тронул два пакета):
```bash
se pipeline docs/plans/<план>.md \
  --validate-cmd 'bun run test:engine-api && bun run test:console'
# оба — vitest по конкретным пакетам (api на pglite, console --project=unit),
# без e2e.
```

## Наблюдение и управление

```bash
se list                # прогоны + сводка: вердикт, ветка, план, токены, ~USD
se show <runId>        # одна деталь + блок DECISION REQUIRED, если прогон припаркован
se logs <runId>        # логи прогона
se chat <runId>        # диалог агентного плеча
se approve <runId>     # принять предложение гейта — НЕ всегда «продолжить» (semantics — ниже)
se deny <runId>        # красный гейт: уронить прогон
se approve|deny <runId> --no-resume   # только записать решение, прогон не двигать
se abort <runId>       # жёсткая остановка
se resume <runId>      # продолжить после паузы/падения процесса
se resume <runId> --force  # то же для убитого прогона, не ожидая протухания heartbeat
```

**Галочка в логе — не вердикт.** Движок печатает `✓ <node>`, когда узел
отработал без исключения; гейт, который решил `failed`, отработал без
исключения и получает ту же галочку, что и зелёный. Вердикт печатает сам
пайплайн отдельным блоком `GATE <стадия>: FAILED` с причинами и с тем, что
сделает approve. Он же лежит в запросе на одобрение — `se show <runId>`
показывает его под заголовком `DECISION REQUIRED`, и `se approve`/`se deny`
печатают его перед тем, как записать решение. Читать статус стадии по галочкам
нельзя: на `run-1786718288581` оператор так одобрил два упавших work-гейта,
приняв «повторить стадию» за «продолжить».

**Решение само по себе прогон не двигает — поэтому `se approve` его и
возобновляет.** Процесс-владелец завершается, когда прогон паркуется:
`runtime_owner_id` очищается, решение ложится в базу, и дальше не происходит
ничего. На `run-1786718288581` одобрение в 16:42:24 не сдвинуло прогон до
ручного `se resume` в 16:44:47. Теперь `se approve` и `se deny` после записи
решения сами возобновляют прогон — но только если владельца нет: живой владелец
означает, что прогон уже кто-то ведёт, а два движка на одном прогоне рушат его
состояние. `--no-resume` записывает решение и не трогает прогон, если надо
пройти несколько гейтов подряд.

Семантика `approve` по гейтам (KTD3):

| Гейт | approve означает |
|---|---|
| verify-doc (P0 severity) | waive, скоупленный предикатом (cause `severity`): approve вейвит только parsed-P0 фейл и продолжает зелёным; severity-суть (пер-плечевые summary, причины гейта, усечённый fail-soft отрывок конвертов) durable ложится в `summary.notes` — не только решение, но содержание (KTD-E) |
| verify-doc (доступность) | красные по доступности (crash `failed`, оба плеча вниз `degraded`, cause `availability`) НЕ вейвятся: approve = одна доп. попытка свежим узлом. Бланкетный флаг дал бы вейвнуть двойной таймаут в прогон вообще без ревью плана |
| work | одна доп. попытка стадии свежим узлом с условным сбросом ветки (конверт есть → нетронутая ветка, нет → reset на pre-stage SHA) |
| secret-scan | waive: принять риск и продолжить (находка/ошибка сканера — по диапазону ИЛИ по дереву — в notes) |
| verify-code (P0) | waive: запись в notes, продолжение |
| rescan (пост-approval) | approve = ОДНА свежая попытка: пере-скан и пере-validate ТЕКУЩЕГО HEAD — рабочий цикл «закоммить фикс → approve»; коммиты, сделанные в паузе, сами попадают под скан. Скоуп `scannedHead..HEAD` (waived-находки base..scannedHead не пере-флагаются); rebase/amend рвёт ancestry → полный диапазон fail-closed. Второй красный → только стоп-с-отчётом |
| вторая пауза того же гейта | только стоп: approve = стоп-с-отчётом, deny = fail |

`deny` всегда роняет прогон. Rollback ветки не автоматизирован — откатывай
ветку целевого репо руками (`git branch -D se/<...>`).

Особенности resume:

- Убитый прогон резюмится `se resume <runId>`; если smithers отвечает
  `RUN_STILL_RUNNING` — heartbeat мёртвого owner'а ещё свеж. Либо подожди
  30–45 с и повтори, либо пропусти ожидание через `se resume <runId> --force`.
  Форсировать можно только прогон с мёртвым процессом-владельцем: два движка
  на одном прогоне портят его состояние. `se resume` печатает подсказку и
  вывод `smithers why`.
- Правка исходников workflow между запуском и resume даёт
  `RESUME_METADATA_MISMATCH`. Лечится флагом: `smithers up
  workflows/se-pipeline.tsx --run-id <id> --resume true
  --accept-workflow-change` — re-bless метаданных; replay-детерминизм с этого
  момента на операторе (движок предупреждает об этом явно).
- **State walk-up:** рантайм-дир зовётся `.smithers`, и smithers считает
  его ЧУЖИМ state-диром → реальная БД лежит уровнем выше
  (`~/.claude/smithers.db`). `se db-path` печатает разрезолвленный путь;
  `se list/show/resume` ходят через него. Свежая БД не имеет
  `_smithers_events` до первой записи — cost-агрегация в summary fail-soft
  (нулевая стоимость лучше упавшего прогона).
- **Упавшая последняя задача с retries=0 не пере-запускается на resume** —
  чинится точечно: `smithers retry-task workflows/se-pipeline.tsx
  --run-id <id> --node-id <node>` (сбрасывает ноду и резюмит).
- **После `se abort`** в целевом репо может остаться `.git/se-run.lock`
  (снять руками: `rm <repo>/.git/se-run.lock`) и пустые worktree/ветка
  (`git worktree prune`, `git branch -D se/<…>`).
- **Шелл со старым `SE_SMITHERS_DIR`** (напр. на source-дир) заставит
  `se pipeline` исполнять workflow из РАБОЧЕГО ДЕРЕВА этого дира — включая
  чужие незакоммиченные правки. Проверяй `echo $SE_SMITHERS_DIR` перед
  запуском; должен быть пуст (дефолт — рантайм).

## Smithers-причуды (актуально в 0.32)

Правила авторинга и эксплуатации воркфлоу:

- Task без явного `retries` ретраится бесконечно с растущим бэкоффом, прогон
  висит в running — каждая Task обязана иметь `retries={0|1}`.
- Отсутствующее опциональное поле `ctx.input` приходит как `null`, не
  `undefined` (Zod-дефолты при этом применяются). `?? default` корректен;
  проверки `=== undefined` не годятся.
- **null на Subflow-границе.** Output subflow'а едет к родителю через
  типизированную SQLite-строку: отсутствующее опциональное поле возвращается
  как NULL, и `z.string().optional()` роняет валидацию ноды. На output-схемах
  subflow-границ — только `.nullish()`, не `.optional()`. Внутрипрогонные
  read-back'и (`ctx.outputMaybe`) NULL терпят — правило касается только границ.
- ClaudeCodeAgent исполняет `jsonSchema` как native structured output — схема
  принуждается движком даже против несговорчивого промпта. Envelope-контракты
  в промптах — страховка, не единственный механизм.
- runId неоднороден: detached `up` даёт `run-<epoch-ms>`, attached `up` — UUID.
  `runIdTail` (последние 8 алфанум) работает для обоих форматов.
- Per-task USD-стоимость не персистится — `TokenUsageReported` несёт только
  токены (usd-цифры встречаются лишь внутри сырых `AgentEvent`-блобов);
  себестоимость считается из токенов (`workflows/lib/cost.ts`).
- Нода `output` сносит снапшот-worktree при finish → `smithers retry-task` на
  ноде завершённого рана невозможен (падает на исчезнувшем worktree), только
  свежий ран.
- `smithers cancel`: ран с мёртвым owner отменяется синхронно из CLI; живой
  owner обрабатывает cancel асинхронно — до 1–2 мин, если задача в
  backoff-паузе. Осиротевшие worktree подчищать руками
  (`git worktree remove --force` + `git worktree prune`).
- Burst-лимитер Anthropic бьёт при 5–6 параллельных headless-сессиях —
  держать concurrency ≤3 (anthropics/claude-code#53922, #62426).
- `timeoutMs` срабатывает с reap-лагом (~+13 мин wall-clock). Wait cap
  вызывающего = maxAttempts × cap + ~15 мин.

## Таксономия отказов review-ноги и salvage

Когда «claude-нога померла», сначала читаем код отказа attempt, а не лезем в
логи с нуля. Три кода на review-плечах (`verify-code`, se-code-review,
se-doc-review):

- **`PROCESS_IDLE_TIMEOUT`** — CLI замолчал (ноль байт в stdout/stderr) дольше
  порога простоя и убит спавн-слоем. Порог живёт в профиле
  (`AGENT_PROFILES.*.idleTimeoutMs`, `workflows/lib/agents.ts`): 15 мин у
  claude-плеч (`codeReview`, `docReview`), 10 мин у `opencodeReview`; таймер
  сбрасывается на каждом байте. Быстрый отказ вместо прожига полного
  `timeoutMs`. У `work` idle-таймера нет — долгие локально-тихие команды
  (install, тесты) легитимны. При `codeReview.retries: 0` ложный idle-kill
  невосстановим; значения провизорны, поднимаются одной строкой профиля, если
  здоровая нога начнёт в них упираться.
- **`PROCESS_TIMEOUT`** — жёсткий кап `timeoutMs` (45 мин codeReview). Доходит
  до вызывающего с reap-лагом ~+13 мин wall-clock — wait cap это учитывает.
- **`AGENT_CLI_ERROR`** — сам процесс CLI вышел с ненулевым кодом посреди
  ревью (наблюдался на huge-diff сессиях). Текст ошибки несёт хвост вывода
  CLI; финального сообщения нет, поэтому salvage невозможен. Корень-причина
  (почему CLI падает на огромных диффах) открыта.
- **Нетерминальный `status` в отчёте ноги** — четвёртый класс, БЕЗ кода
  отказа: CLI выходит «успешно», но отчёт несёт `waiting_for_reviewers` /
  `failed` / прочее in-flight-состояние. Причина: с claude ≥2.1.198
  сабагенты уходят в фон по умолчанию, а headless `-p` ждёт фоновые не
  дольше 10 мин — нога с шестью персонами умирает до синтеза, salvage
  подбирает промежуточный объект валидной формы. Двойная защита:
  `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` в env всех claude-агентов
  (`lib/agents.ts`) выключает фон на корню, а `parseLeg`
  (`lib/review-merge.ts`) считает ногу с таким статусом failed — дальше
  работает штатная degraded/pause-семантика гейта вместо тихой
  ноги-с-нулём-находок.
- **Годность статуса решает payload, а не прилагательное**
  (`isUsableReviewLegStatus`, `lib/review-schema.ts`). Порядок проверок:
  отсутствующий, не-строковый или пустой статус — failed (fail-closed живёт
  здесь: отсутствие свидетельства не есть здоровье); отрицание успеха
  («not completed») — failed; слово успеха — ok; явный отказ или
  in-flight-состояние (`failed`, `error`, `timed out`, `pending`, `running`,
  `waiting_for_reviewers`, `partial`, …) — failed; всё остальное — ok, потому
  что вызывающий уже потребовал распарсенный массив `findings`, и этот массив
  и есть доказательство, что нога отработала. Незнакомое слово вроде
  `findings` больше не выбрасывает здоровую ногу вместе с её находками. Все
  проверки идут по границам слов, разделители нормализуются в пробелы
  (`waiting_for_reviewers` иначе не ловится), отрицание считается в обе
  стороны («no errors» — здоровье, не отказ).

Путь захвата вывода — встроенный в движок, воркфлоу-парсер не нужен: после
финального сообщения движок прогоняет 5-стратегийный salvage-каскад (вплоть до
`extractLastBalancedJson`), затем до `maxSchemaRetries` (дефолт 3)
schema-correction вызовов; correction пропускается при нулевом остатке
бюджета. Поэтому кастомный «достань последний JSON» парсер на стороне воркфлоу
— мёртвый код.

Контракт отчёта code-review-плеч — натуральный объект ревью (верхнеуровневое
строковое поле `status`, остальные поля проходят насквозь), единый источник
`workflows/lib/review-schema.ts`, импортируется se-code-review и verify-code —
без обёртки `{"report": "<строка>"}`. salvage и native structured output
приземляются на одну и ту же форму. docReview-обёртка `{"envelope": "..."}` и
work-обёртка `{"report": "..."}` не тронуты.

Диагностика кода отказа attempt:

```sh
sqlite3 ~/.claude/smithers.db \
  "SELECT node_id, error_json FROM _smithers_attempts WHERE run_id='<runId>';"
```

## Провенанс и пост-approval рескан

- **Провенанс gate-0 (R1/R2).** Строка-хэш плана (`gate0`) — авторитет с
  привязкой: `ctx.prove(outputs.gate0)` даёт digest строки, а `bind={gate0Proof}`
  висит на дорогих плечах (`work`, `work-extra`, `summary`). Движок сверяет
  digest на каждом рендере и прямо перед каждым dispatch; любая позднейшая
  мутация строки `gate0` (баг, ручная правка sqlite, частичный restore)
  переводит привязанные задачи в `bound-stale`, а прогон паркуется
  (`BOUND_STALE` / `waiting-event`) БЕЗ траты retries. Провенанс — только
  целостность строки-цепочки: он не читает ФС, поэтому ре-хэш плана-файла в
  work-гейте остаётся файловым стражем (правка самого файла плана по-прежнему
  роняет work-гейт по mismatch, R2).
- **Пост-approval рескан (R3–R6).** Между зелёным verify-code и терминальным
  зелёным стоит стадия `rescan`: compute-задача читает SHA, отсканированный
  секрет-сканом (`scannedHead` в его отчёте), и сравнивает с текущим HEAD
  worktree. HEAD не двигался → детерминированный no-op green. HEAD сдвинулся
  (или `scannedHead` отсутствует — fail-closed) → повторный `secretScanDiff` +
  `runValidateCmd` по новым коммитам; вердикт — `rescanGate` (fail-closed:
  утечка/краш сканера → degraded, красный/отсутствующий validate или
  непарсимый отчёт → failed). Так коммиты, которые оператор добавляет на ветку
  во время verify-code паузы, не проходят мимо секрет-скана и validate-cmd.
  Красный рескан паузит на Approval с waive-семантикой (см. таблицу): approve =
  принять свои коммиты (waive в notes), deny = fail, вторая красная — стоп с
  отчётом.

**Восстановление после `BOUND_STALE`:** прогон встал в `waiting-event`, привязанная
задача — `bound-stale`. Причина — строка `gate0` больше не совпадает с digest,
под который дали authority. Диагностика: `smithers why <runId>` (или `se logs`)
покажет расхождение привязки. Лечение: либо восстанови исходную строку `gate0`
(откати ручную правку), либо переиздай authority-строку (перезапусти прогон от
плана, если план валиден), затем `se resume <runId>`. Мемоизация: завершённые
(finished) задачи НЕ пере-сверяют bind — привязка стережёт планирование, не
историю; уже отработавшее плечо не откатывается задним числом при позднейшем
рассинхроне.

### Приёмка провенанса и рескана

Отдельные от базовых AE1–AE4 ниже — эти проверяют рескан и bind (движковое
поведение, не покрываемое юнит-тестами; сам `rescanGate` покрыт юнит-тестами):

- **AE1 (секрет в коммите оператора → красный рескан):** запусти прогон до
  verify-code паузы (например, waive P0 или красный P0). На ветке прогона в
  worktree (`/tmp/se-pipeline/se-<...>`) сделай коммит с файлом, содержащим
  `awsAccessKeyId = "AKIA<16 заглавных>"`, затем `se approve <runId>` (verify-code
  waive). Рескан увидит сдвинутый HEAD → `secretScanDiff` найдёт утечку → degraded
  → пауза. `se approve` = green с waive-заметкой в summary; `se deny` = прогон падает.
- **AE2 (коммит оператора ломает validate → красный рескан):** тот же сценарий, но
  коммит ломает validate-cmd (например, синтаксическая ошибка в тесте). Рескан:
  скан чист, validate ≠ 0 → failed → та же Approval-семантика.
- **AE3 (нет коммитов оператора → no-op green):** обычный прогон без ручных
  коммитов в паузе. Рескан-compute видит неподвижный HEAD (`currentHead ==
  scannedHead`) → green без повторного скана/validate.
- **AE4 (мутация строки gate0 → BOUND_STALE):** на паузе прогона (любой Approval)
  `sqlite3 ~/.claude/.smithers/smithers.db "UPDATE gate0 SET plan_hash='tampered'
  WHERE run_id LIKE '%<runid8>%'"`, затем `se resume <runId>`. Ожидание: прогон
  паркуется `waiting-event` + `BOUND_STALE` в `smithers why`, а не продолжает
  против устаревшей authority.

## Фикстурные демо базового конвейера (AE1–AE4)

(Базовые приёмочные примеры конвейера; приёмка рескана — в разделе выше.)
Фикстурный мини-репо генерируется скриптом (воспроизводимо):

```bash
FIXTURE=$(~/Projects/my-mac-setup/tests/fixtures/make-pipeline-fixture.sh)
cd "$FIXTURE"
```

- **AE1 (полный зелёный прогон):**
  `se pipeline docs/plans/fixture-reverse-plan.md --validate-cmd 'bun test'` →
  ветка с ОДНИМ коммитом от work-гейта (агент не коммитит — коммитит
  мемоизируемая gate-задача через `commitWorkGuarded`, только если дерево
  грязное), proof-of-work = tree-хэш (`baseTree ≠ headTree`), `final_commit_sha`
  в конверте advisory; ревью-отчёт, `se list` со стоимостью.
- **AE2 (красный гейт → Approval):** детерминированный вариант — секрет в
  диффе: до запуска добавь в план юнита требование записать строку
  `awsAccessKeyId = "AKIA<16 заглавных>"` в файл конфига; секрет-скан gitleaks
  переведёт гейт в degraded → пауза ДО внешней отправки кода; `se approve` =
  waive, `se deny` = стоп.
- **AE3 (терминал умер — прогон жив):** запусти detached, `kill -9 <pid>` во
  время work, подожди 45 с, `se resume <runId>` — пройденные стадии
  мемоизированы (не переоплачиваются), work перезапускается, прогон доходит до
  green. Дубля коммита нет и на kill в окне commit→persist: guard
  `commitWorkGuarded` коммитит только грязное дерево, resume видит чистое и
  пропускает.
- **AE4 (невалидный вход):** requirements-only план / несуществующий файл /
  `--until=pr` → прогон падает сразу, причина в `error` и `se logs`.
- **AE5 (verify-doc P0-пауза через smoke-инъекцию severity, R8):** smoke-плечи
  возвращают `SMOKE OK` и НЕ эмитят SEVERITY-строку, поэтому R8 недостижим без
  тест-инъекции (KTD-F). Прокинь `smokeSeverity` на входе — output-задача
  se-doc-review штампует его в оба severity-поля, минуя парсинг конверта:

  ```bash
  # P0-пауза: прогон паркуется waiting-approval на gate-verify-doc
  smithers up workflows/se-pipeline.tsx --input '{
    "planPath":"'"$FIXTURE"'/docs/plans/fixture-reverse-plan.md",
    "smoke":true,
    "smokeSeverity":{"maxSeverity":"P0","p0Count":1,"p1Count":0},
    "validateCmd":"bun test"
  }'
  # se approve <runId> → waive: прогон продолжается зелёным, waive-заметка с
  #   severity-сутью в summary.notes; verify-doc.result.json в reportDir несёт
  #   severity-поля. Причина waive-скоупа — cause "severity" (не "availability").

  # Регрессия pass-through: без smokeSeverity severity-поля отсутствуют,
  #   gate-verify-doc зелёный сквозной — штатное поведение.
  smithers up workflows/se-pipeline.tsx --input '{
    "planPath":"'"$FIXTURE"'/docs/plans/fixture-reverse-plan.md",
    "smoke":true, "validateCmd":"bun test"
  }'
  ```
  Инъекция доказывает проводку гейта и waive end-to-end; корректность парсера
  против реальных конвертов проверяется юнит-тестами `severity-summary.test.ts`
  и `gates.test.ts` (KTD-F).

## Стоимость

Smithers не персистит USD — только токены (`TokenUsageReported`).
Авторитетный стор — выходная `summary` прогона: токены по плечам +
`est_cost_usd`, посчитанный официальной таблицей
`smithers-orchestrator/scorers` (`estimateCostUsd`/`modelTokenPrices`) через
`workflows/lib/cost.ts` (приближение; первичная метрика — токены).
Особенности прайсинга: провайдер-префикс (`openai/…`) срезается перед
лукапом; неизвестная таблице модель (голый `claude`, null) прайсится как
sonnet-класс, не $0; `cacheWriteTokens` входит в цену и totalTokens.
`se list` читает только оттуда. Ориентир: смоук ≈ $0.15; полный фикстурный
прогон (реальные work + simplify + review) ≈ $1–1.5; рабочая задача — десятки
(бюджеты-предохранители: $15 ревью-плечи, $50 work).

## Сравнительная фаза (F3, приёмка)

1. Подбери рабочую задачу с готовым implementation-ready планом.
2. Ручной трек: делаешь задачу сам, как обычно.
3. Параллельно: `se pipeline <план> --validate-cmd '<команда репо>'` c
   `--until=branch` — пайплайн оставит ветку `se/<…>`.
4. Сравни ветки руками: полнота, качество, тесты; стоимость — `se list`.
5. Наблюдения пиши в план (Open Questions / журнал фазы).

Чек-лист включения `--until=pr` (ориентир, решение субъективное — Success
Criteria):

- [ ] ≥3 прогонов подряд на рабочих задачах без P0-находок в verify-code;
- [ ] секрет-скан чист во всех прогонах (без waive);
- [ ] ни одного зависшего/потерянного прогона (resume всегда доводил);
- [ ] дельта стоимости к ручному треку приемлема (решает оператор).

## Известные ограничения

- **KTD12:** work-агент без allow/deny-листа инструментов
  (`bypassPermissions` — headless-коммиты требуют Bash; изоляция — worktree и
  cwd). Гонять только на доверенных задачах до dev-container-фазы.
- **Мемоизация bind:** завершённые задачи не пере-сверяют ProofBinding —
  привязка стережёт планирование, не историю. Мутация строки `gate0` паркует
  ещё не запущенные привязанные плечи (`BOUND_STALE`), но не откатывает уже
  отработавшие (KTD-A).
- Self-reported P0-счётчик ревью не сверяется независимо (KTD3, принятый риск).
- USD — оценка по прайс-таблице, не биллинг.
- Бэкап `~/.claude/.smithers/` не делается — переустановка машины теряет
  историю прогонов (принято).
- Правка workflow-исходников между запуском и resume требует
  `--accept-workflow-change` (см. «Особенности resume»); replay-детерминизм
  после re-bless — на операторе.
