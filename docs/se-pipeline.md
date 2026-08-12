# se-pipeline — раннбук

Durable-прогон `verify-doc → work → verify-code` над целевым репозиторием на
Smithers 0.32.0 (апгрейд 0.29→0.32 2026-08-12: hardening-релиз, завершённая
Effect-4-миграция диспатча, `--accept-workflow-change` для resume после правки
workflow-исходников; smoke green `run-1786538882578`, 200/200 тестов).
Без локальных патчей (фикс false-positive квота-классификатора
org_level_disabled, upstream smithersai/smithers#1342, влит в 0.29.0 — `patches/`
и `patchedDependencies` удалены при апгрейде 2026-07-22; detached-логи теперь в
`.smithers/logs/` с ретеншном). План: `docs/plans/2026-07-14-001-feat-smithers-pipeline-plan.md`
(gitignored). Исходники: `home/private_dot_claude/dot_smithers/` (chezmoi →
`~/.claude/.smithers`); состояние прогонов (`smithers.db`, `.smithers/`) живёт в
рантайм-дире и в git не попадает.

Модели плеч запинены константами в `se-pipeline.tsx`: work —
`claude-opus-4-8` (fallback `claude-sonnet-5`), review — `claude-sonnet-5`
(fallback `claude-haiku-4-5`); донор doc-review (`se-doc-review.tsx`) —
`claude-sonnet-5`/`claude-haiku-4-5`.

Verify-code с 2026-07-23 повторяет форму se-code-review: два независимых
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

Verify-doc с 2026-07-24 блокирует по P0 находкам ревью плана (симметрия с
codeReviewGate). Каждое не-smoke плечо эмитит машиночитаемую строку
`SEVERITY: {"maxSeverity":"P0|P1|P2|none","p0Count":N,"p1Count":N}` в защищённом
слоте — последняя непустая строка прямо перед финальным `Review complete`;
парсер (`lib/severity-summary.ts`) читает ТОЛЬКО этот слот (декой `SEVERITY:` в
теле конверта инертен), при отсутствии/невалидном JSON/отрицательных счётчиках →
`undefined`. Envelope-контракт (`≥500` симв., последняя строка `Review complete`,
`SMOKE OK`-байпас) не тронут — severity-слой никогда не влияет на валидность
конверта. Гейт: любое доступное плечо с `p0Count > 0` → `failed` (max-of-legs,
fail-closed — один P0 блокирует, даже если второе плечо 0); P1 — advisory
(суммируется, не блокирует); отсутствие severity деградирует ЭТО плечо к прежнему
поведению «только доступность» (R5). Слоение толерантности (KTD-D): доступность
плеч остаётся fail-closed (нет вывода → `failed`, оба плеча вниз → `degraded`),
а severity-слой лишь ДОБАВЛЯЕТ блокирующую силу — его отсутствие возвращает гейт
ровно к сегодняшнему поведению, никогда ниже. Пер-плечевой статус парса severity
(parsed/missing) пишется в notes и `verify-doc.result.json` каждый прогон —
системный отказ контракта виден, а не тихо инертен. SEVERITY-строка выстригается
из конверта перед инъекцией в work-промпт (`readDocReviewAdvisory`) и из синтеза
standalone-скилла — это вход гейта, не контент ревью.

## Стадия simplify и два входа (se-work / se-review-and-work)

С 2026-07-27 у пайплайна два именованных входа над ОДНИМ `se-pipeline.tsx` и
одним внутренним ключом `docReview` (пользователь его не печатает — вход выбирает
команда):

- **`se-work`** — `docReview:false`: `work → simplify → verify-code → branch/PR`,
  БЕЗ plan-review. Для уже подготовленного, отревьюенного человеком плана.
- **`se-review-and-work`** — `docReview:true`: то же плюс `verify-doc` впереди
  (`verify-doc → work → simplify → verify-code`). CLI: `se pipeline … --doc-review`.

Стадия `verify-doc` теперь условная (рендерится только при `docReview:true`); при
`false` `work` привязан прямо к gate-0, и в summary `verify-doc` = `null`.

**Simplify — постоянная стадия в ОБОИХ командах**, не флаг. Вставлена ПОСЛЕ
общего secret-scan (её внешние отчётные ноги видят только уже прочищенный
сканом контент — KTD10) и ПЕРЕД verify-code (ревью идёт по уже прибранному коду).
Это `Subflow` над `se-simplify.tsx` (тот же приём, что `se-doc-review.tsx`), с
`repoPath: staged.worktreePath` — ИЗОЛИРОВАННЫЙ worktree прогона, никогда не
launch-checkout оператора (KTD-G).

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
стешить». Голый `stash create` на stat-dirty дереве — validate-cmd переписал
tracked-файл байт-в-байт ПОСЛЕ gate-коммита, индекс не освежался — молча
выходит с кодом 1 и ронял стадию мгновенно (run-1786528537862, 2026-08-12,
platform). Диагностический признак в `_smithers_attempts`: у ноды `stage`
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
  На первом реальном прогоне (platform, PRD-2099) именно `bun test` в корне
  утянул playwright и упал по ETIMEDOUT — гейт покраснел на таймауте, не на
  провале тестов.
- **Скоупь по затронутой области, не по корню.** Смотри `Files:` юнитов плана
  / где легли коммиты work. Монорепа: фильтруй пакет
  (`turbo run test --filter=<pkg>`, `nx test <pkg>`, `pnpm --filter <pkg> test`).
- **Unit/type, не e2e.** Годится: `tsc --noEmit`, `<runner> --project=unit`,
  vitest с in-memory БД (pglite и т.п.). Не годится для гейта: playwright/`e2e/`,
  тесты с реальной БД/сетью/браузером — worktree прогона это чистый checkout от
  committed HEAD, сервисов там нет.
- **Проверь руками до запуска.** Прогони кандидата в репо, засеки. >2–3 мин или
  нужен dev-сервер/БД/сеть → не подходит.
- **Комбинируй дёшево:** `tsc --noEmit && <узкий unit-скрипт>`.
- **Таймаут — страховка, не решение.** `--validate-timeout` поднимает потолок,
  но синхронный длинный прогон блокирует heartbeat движка (spawnSync) — правильно
  сузить команду.

Пример (platform PRD-2099, тронул `@membranehq/api` + `@membranehq/console`):
```bash
se pipeline docs/plans/<план>.md \
  --validate-cmd 'bun run test:engine-api && bun run test:console'
# оба — vitest по конкретным пакетам (api на pglite, console --project=unit),
# без e2e; вместо утянувшего playwright 'bun test' в корне.
```

## Наблюдение и управление

```bash
se list                # прогоны + сводка: вердикт, ветка, план, токены, ~USD
se logs <runId>        # логи прогона
se chat <runId>        # диалог агентного плеча
se approve <runId>     # красный гейт: продолжить (semantics — ниже)
se deny <runId>        # красный гейт: уронить прогон
se abort <runId>       # жёсткая остановка
se resume <runId>      # продолжить после паузы/падения процесса
```

Семантика `approve` по гейтам (KTD3):

| Гейт | approve означает |
|---|---|
| verify-doc (P0 severity) | waive, скоупленный предикатом (cause `severity`): approve вейвит только parsed-P0 фейл и продолжает зелёным; severity-суть (пер-плечевые summary, причины гейта, усечённый fail-soft отрывок конвертов) durable ложится в `summary.notes` — не только решение, но содержание (KTD-E) |
| verify-doc (доступность) | красные по доступности (crash `failed`, оба плеча вниз `degraded`, cause `availability`) НЕ вейвятся: approve = одна доп. попытка свежим узлом. Бланкетный флаг дал бы вейвнуть двойной таймаут в прогон вообще без ревью плана |
| work | одна доп. попытка стадии свежим узлом с условным сбросом ветки (конверт есть → нетронутая ветка, нет → reset на pre-stage SHA) |
| secret-scan | waive: принять риск и продолжить (находка/ошибка сканера в notes) |
| verify-code (P0) | waive: запись в notes, продолжение |
| rescan (пост-approval) | approve = ОДНА свежая попытка: пере-скан и пере-validate ТЕКУЩЕГО HEAD — рабочий цикл «закоммить фикс → approve»; коммиты, сделанные в паузе, сами попадают под скан. Скоуп `scannedHead..HEAD` (waived-находки base..scannedHead не пере-флагаются); rebase/amend рвёт ancestry → полный диапазон fail-closed. Второй красный → только стоп-с-отчётом |
| вторая пауза того же гейта | только стоп: approve = стоп-с-отчётом, deny = fail |

`deny` всегда роняет прогон. Rollback ветки не автоматизирован — откатывай
ветку целевого репо руками (`git branch -D se/<...>`).

Известные особенности resume (проверено спайком U1):

- Убитый прогон резюмится `se resume <runId>`; если smithers отвечает
  `RUN_STILL_RUNNING` — heartbeat мёртвого owner'а ещё свеж, подожди 30–45 с;
  `se resume` печатает подсказку и вывод `smithers why`.
- Правка исходников workflow между запуском и resume даёт
  `RESUME_METADATA_MISMATCH`. С 0.32 такой прогон можно продолжить:
  `smithers up workflows/se-pipeline.tsx --run-id <id> --resume true
  --accept-workflow-change` (флаг из upgrade-notes 0.32; на реальном
  прогоне пока не проверен). До 0.32 — только перезапуск заново.
- **0.28 state walk-up:** рантайм-дир зовётся `.smithers`, и smithers считает
  его ЧУЖИМ state-диром → реальная БД лежит уровнем выше
  (`~/.claude/smithers.db`). `se db-path` печатает разрезолвленный путь;
  `se list/show/resume` ходят через него. Свежая 0.28-БД не имеет
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

## Smithers-причуды (проверено прогонами; актуально в 0.29, на 0.32 не пере-проверены)

Правила авторинга воркфлоу; не изменились в 0.28/0.29. После апгрейда на
0.32 (hardening-батч, 251 фикс) каждая причуда — кандидат на снятие, но ни
одна не пере-проверена реальным прогоном — сверяй при первом столкновении:

- Task без явного `retries` ретраится бесконечно (прогон висит в running) —
  каждая Task обязана иметь `retries={0|1}`.
- `ctx.input` приходит без Zod-дефолтов — коалесцировать каждое опциональное
  поле (`?? default`).
- ClaudeCodeAgent не умеет native structured output — envelope-контракт в
  промпте обязателен. Невалидный envelope → smithers МОЛЧА перезапускает весь
  агентный прогон внутри той же attempt: кап Subflow ≥ 2× длительности самой
  долгой ноги.
- `timeoutMs` срабатывает с reap-лагом (~+13 мин wall-clock). Wait cap
  вызывающего = maxAttempts × cap + ~15 мин.
- runId `run-<epoch-ms>` уникален только хвостом (`runIdTail`, последние
  8 алфанум).
- Глобальная политика «NEVER commit unless asked» из ~/.claude/CLAUDE.md
  протекает в headless `claude -p` — work-промпт обязан явно просить коммит.
- Burst-лимитер Anthropic бьёт при 5–6 параллельных headless-сессиях —
  держать concurrency ≤3 (anthropics/claude-code#53922, #62426).
- Per-task USD-стоимость не персистится — только токены (`TokenUsageReported`
  в `_smithers_events`); себестоимость считается из токенов
  (`workflows/lib/cost.ts`).
- Нода `output` сносит снапшот-worktree при finish → `smithers retry-task` на
  ноде завершённого рана невозможен, только свежий ран.
- `smithers cancel` рана с мёртвым владельцем оставляет статус running
  навсегда + worktree (cancel некому обработать; force-флага у CLI 0.29 нет).
  Добивать руками: `git -C <repo> worktree remove --force <path>` + `git
  worktree prune`; в DB `UPDATE _smithers_runs SET status='cancelled',
  finished_at_ms=<now> WHERE run_id=? AND status='running' AND
  runtime_owner_id='<мёртвый pid>'` — guard по owner_id обязателен, чтобы не
  тронуть живой ран.

## Таксономия отказов review-ноги и salvage (актуально в 0.29)

Когда «claude-нога померла», сначала читаем код отказа attempt, а не лезем в
логи с нуля. Три кода на review-плечах (`verify-code`, se-code-review,
se-doc-review):

- **`PROCESS_IDLE_TIMEOUT`** — CLI замолчал (ноль байт в stdout/stderr) дольше
  порога простоя и убит спавн-слоем. Порог живёт в профиле
  (`AGENT_PROFILES.*.idleTimeoutMs`, `workflows/lib/agents.ts`): 15 мин у
  claude-плеч (`codeReview`, `docReview`), 10 мин у `opencodeReview`; таймер
  сбрасывается на каждом байте. Быстрый отказ вместо прожига полного
  `timeoutMs` (прогон 9925bb0d съел 45-мин кап на 10-мин зависании). У `work`
  idle-таймера нет — долгие локально-тихие команды (install, тесты) легитимны.
  При `codeReview.retries: 0` ложный idle-kill невосстановим; значения
  провизорны, поднимаются одной строкой профиля, если здоровая нога начнёт в
  них упираться.
- **`PROCESS_TIMEOUT`** — жёсткий кап `timeoutMs` (45 мин codeReview). Доходит
  до вызывающего с reap-лагом ~+13 мин wall-clock — wait cap это учитывает.
- **`AGENT_CLI_ERROR`** — сам процесс CLI вышел с ненулевым кодом посреди
  ревью (прогон 89938dd6, huge-diff сессия). Текст ошибки несёт хвост вывода
  CLI; финального сообщения нет, поэтому salvage невозможен. Класс
  задокументирован, но НЕ чинится этим планом (отложено: корень-причина, почему
  CLI падает на огромных диффах).

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
  "SELECT node_id, error_json FROM _smithers_attempts WHERE run_id='<runId>' ORDER BY id;"
```

## Провенанс и пост-approval рескан (Batch 5)

Два зазора MVP закрыты (план
`docs/plans/2026-07-16-001-feat-se-pipeline-provenance-rescan-plan.md`):

- **Провенанс gate-0 (R1/R2).** Строка-хэш плана (`gate0`) теперь авторитет с
  привязкой: `ctx.prove(outputs.gate0)` даёт digest строки, а `bind={gate0Proof}`
  висит на дорогих плечах (`work`, `work-extra`, `summary`). Движок сверяет
  digest на каждом рендере и прямо перед каждым dispatch; любая позднейшая
  мутация строки `gate0` (баг, ручная правка sqlite, частичный restore)
  переводит привязанные задачи в `bound-stale`, а прогон паркуется
  (`BOUND_STALE` / `waiting-event`) БЕЗ траты retries. Провенанс — только
  целостность строки-цепочки: он не читает ФС, поэтому ре-хэш плана-файла в
  work-гейте остаётся файловым стражем (правка самого файла плана по-прежнему
  роняет work-гейт по mismatch, R2).
- **Пост-approval рескан (R3–R6).** Коммиты, которые оператор добавляет на ветку
  во время verify-code паузы, раньше проходили мимо секрет-скана (сканировал
  `base..HEAD` раньше) и validate-cmd (гонялся на work-гейте) — утёкший секрет
  или сломанный билд мог доехать до зелёного на waive. Теперь между зелёным
  verify-code и терминальным зелёным стоит стадия `rescan`: compute-задача
  читает SHA, отсканированный секрет-сканом (`scannedHead` в его отчёте), и
  сравнивает с текущим HEAD worktree. HEAD не двигался → детерминированный
  no-op green (прогоны без коммитов оператора ведут себя как раньше, +1
  compute-узел). HEAD сдвинулся (или `scannedHead` отсутствует — fail-closed) →
  повторный `secretScanDiff` + `runValidateCmd` по новым коммитам; вердикт —
  `rescanGate` (fail-closed: утечка/краш сканера → degraded, красный/отсутствующий
  validate или непарсимый отчёт → failed). Красный рескан паузит на Approval с
  waive-семантикой (см. таблицу): approve = принять свои коммиты (waive в notes),
  deny = fail, вторая красная — стоп с отчётом.

**Восстановление после `BOUND_STALE`:** прогон встал в `waiting-event`, привязанная
задача — `bound-stale`. Причина — строка `gate0` больше не совпадает с digest,
под который дали authority. Диагностика: `smithers why <runId>` (или `se logs`)
покажет расхождение привязки. Лечение: либо восстанови исходную строку `gate0`
(откати ручную правку), либо переиздай authority-строку (перезапусти прогон от
плана, если план валиден), затем `se resume <runId>`. Мемоизация: завершённые
(finished) задачи НЕ пере-сверяют bind — привязка стережёт планирование, не
историю; уже отработавшее плечо не откатывается задним числом при позднейшем
рассинхроне.

### Приёмка Batch 5 (провенанс + рескан)

Отдельные от базовых AE1–AE4 ниже — эти проверяют рескан и bind (движковое
поведение, не покрываемое юнит-тестами; U1 покрыт юнит-тестами `rescanGate`):

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
  scannedHead`) → green без повторного скана/validate; набор вердиктов и состояние
  ветки совпадают с прогоном до Batch 5 (кроме лишнего узла `rescan` в дереве).
- **AE4 (мутация строки gate0 → BOUND_STALE):** на паузе прогона (любой Approval)
  `sqlite3 ~/.claude/.smithers/smithers.db "UPDATE gate0 SET plan_hash='tampered'
  WHERE run_id LIKE '%<runid8>%'"`, затем `se resume <runId>`. Ожидание: прогон
  паркуется `waiting-event` + `BOUND_STALE` в `smithers why`, а не продолжает
  против устаревшей authority. Проверяется вживую однократно как фикстурная демо
  (движковое поведение, не юнит-тест).

## Фикстурные демо базового конвейера (AE1–AE4)

(Базовые приёмочные примеры конвейера; приёмка Batch 5 — в разделе выше.)
Фикстурный мини-репо генерируется скриптом (воспроизводимо):

```bash
FIXTURE=$(~/Projects/my-mac-setup/tests/fixtures/make-pipeline-fixture.sh)
cd "$FIXTURE"
```

- **AE1 (полный зелёный прогон):**
  `se pipeline docs/plans/fixture-reverse-plan.md --validate-cmd 'bun test'` →
  ветка с ОДНИМ коммитом от work-гейта (агент не коммитит — см. KTD5 ниже),
  proof-of-work = tree-хэш (`baseTree ≠ headTree`), `final_commit_sha` в
  конверте advisory; ревью-отчёт, `se list` со стоимостью. Последняя демонстрация — по этому
  раннбуку на фикстуре из скрипта: runId `run-1784105778671` (2026-07-15,
  запуск через `se`, ветка `se/fixture-reverse-plan-05778671`, коммит
  `496c8a9 feat(reverse)`, ревью P0=0, 1.05M токенов ≈ $0.75 старой
  таблицей, ≈$0.83 официальной с cacheWrite; ранее —
  `run-1784104646189`, «Ready to merge»). Smoke-путь 0.28 после патча:
  `run-1784198676339` (4 гейта green, один gate-коммит).
- **AE2 (красный гейт → Approval):** детерминированный вариант — секрет в
  диффе: до запуска добавь в план юнита требование записать строку
  `awsAccessKeyId = "AKIA<16 заглавных>"` в файл конфига; секрет-скан gitleaks
  переведёт гейт в degraded → пауза ДО внешней отправки кода; `se approve` =
  waive, `se deny` = стоп. Механика Approval вживую: runId `ac93562e-…`
  (U3, красный work-гейт → approve → доп. попытка → finished),
  `2639cd70-…` (waive P0). Реальный P0-кейс — материал сравнительной фазы.
- **AE3 (терминал умер — прогон жив):** запусти detached, `kill -9 <pid>` во
  время work, подожди 45 с, `se resume <runId>` — пройденные стадии
  мемоизированы (не переоплачиваются), work перезапускается, прогон доходит до
  green. Демонстрации: `run-1784109630941` (2026-07-15, live U4, smoke: kill
  посреди work → resume восстановил repo из gate0 → finished green; заодно
  подтвердил sweep осиротевшего лока предыдущего terminal-прогона).
  **KTD5 (дубль коммита) закрыт git-only фиксом (U9, 2026-07-16):** work-агент
  больше НЕ коммитит; коммитит одна мемоизируемая gate-задача через
  `commitWorkGuarded` (только если дерево грязное) → kill в окне
  commit→persist безопасен: resume видит чистое дерево, guard пропускает,
  дубля нет. Подтверждено e2e `run-1784204259645` (owner убит в момент
  появления gate-коммита → force-resume → finished, на ветке ровно один
  коммит). Историческая демонстрация дубля на 0.27: `run-1784109630941`
  (2× `chore: smoke commit`). Ранее: `run-1784036851218` (U1-спайк: kill
  после ЗАВЕРШЁННОЙ задачи → мемоизация → без дублей).
- **AE4 (невалидный вход):** requirements-only план / несуществующий файл /
  `--until=pr` → прогон падает сразу, причина в `error` и `se logs`.
  Продемонстрировано тремя прогонами U3 (все `status: failed`, `gate-0 refused: …`).
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
  #   gate-verify-doc зелёный сквозной, поведение как сегодня.
  smithers up workflows/se-pipeline.tsx --input '{
    "planPath":"'"$FIXTURE"'/docs/plans/fixture-reverse-plan.md",
    "smoke":true, "validateCmd":"bun test"
  }'
  ```
  Инъекция доказывает проводку гейта и waive end-to-end; корректность парсера
  против реальных конвертов проверяется юнит-тестами `severity-summary.test.ts`
  и `gates.test.ts` (KTD-F).

## Стоимость

Smithers (и 0.28.0) не персистит USD — только токены (`TokenUsageReported`).
Авторитетный стор — выходная `summary` прогона: токены по плечам +
`est_cost_usd`, посчитанный официальной таблицей
`smithers-orchestrator/scorers` (`estimateCostUsd`/`modelTokenPrices`) через
`workflows/lib/cost.ts` (приближение; первичная метрика — токены).
Особенности прайсинга: провайдер-префикс (`openai/…`) срезается перед
лукапом; неизвестная таблице модель (голый `claude`, null) прайсится как
sonnet-класс, не $0; `cacheWriteTokens` входит в цену и totalTokens.
`se list` читает только оттуда. Ориентир: смоук ≈ $0.13; полный фикстурный
прогон (реальные doc-review + work + review) — единицы долларов (AE1 ≈
$0.83); рабочая задача — десятки (бюджеты-предохранители: $15 ревью-плечи,
$50 work).

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

## Известные ограничения (MVP)

- ~~KTD5-отклонение (дубль коммита на kill-пути)~~ **закрыто** git-only
  фиксом U9 (guarded gate commit + tree-хэш proof), подтверждено e2e
  `run-1784204259645`. Branch-reset по-прежнему только на approve-пути —
  теперь этого достаточно.
- ~~Остаток ревью U4–U7 п.1 (коммиты оператора в verify-code паузе минуют
  секрет-скан и validate-cmd)~~ **закрыто** пост-approval рескан-стадией
  (Batch 5, R3–R6) — см. «Провенанс и пост-approval рескан».
- **KTD12:** work-агент без allow/deny-листа инструментов
  (`bypassPermissions` — headless-коммиты требуют Bash; изоляция — worktree и
  cwd). Гонять только на доверенных задачах до dev-container-фазы.
- **Мемоизация bind:** завершённые задачи не пере-сверяют ProofBinding —
  привязка стережёт планирование, не историю. Мутация строки `gate0` паркует
  ещё не запущенные привязанные плечи (`BOUND_STALE`), но не откатывает уже
  отработавшие (Batch 5, KTD-A).
- Self-reported P0-счётчик ревью не сверяется независимо (KTD3, принятый риск).
- USD — оценка по прайс-таблице, не биллинг.
- Бэкап `~/.claude/.smithers/` не делается — переустановка машины теряет
  историю прогонов (принято).
- Правка workflow-исходников делает in-flight прогоны нерезюмируемыми.
