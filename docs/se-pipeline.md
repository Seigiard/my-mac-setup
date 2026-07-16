# se-pipeline — раннбук

Durable-прогон `verify-doc → work → verify-code` над целевым репозиторием на
Smithers 0.28.0 с локальным bun-патчем `@smithers-orchestrator/agents`
(`patches/` — false positive квота-классификатора на подписке без usage
credits, upstream smithersai/smithers#1342; при апгрейде пакета проверить,
не влит ли фикс). План: `docs/plans/2026-07-14-001-feat-smithers-pipeline-plan.md`
(gitignored). Исходники: `home/private_dot_claude/dot_smithers/` (chezmoi →
`~/.claude/.smithers`); состояние прогонов (`smithers.db`, `.smithers/`) живёт в
рантайм-дире и в git не попадает.

Модели плеч запинены константами в `se-pipeline.tsx`: work —
`claude-opus-4-8` (fallback `claude-sonnet-5`), review — `claude-sonnet-5`
(fallback `claude-haiku-4-5`); донор doc-review (`se-doc-review.tsx`) —
`claude-sonnet-5`/`claude-haiku-4-5`.

## Запуск

Из целевого репозитория (cwd = репо):

```bash
se pipeline docs/plans/<план>.md --validate-cmd 'bun test'
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

## validate-cmd: по умолчанию из плана

work-гейт гоняет validate-cmd **синхронно с таймаутом** (дефолт 600 с,
`--validate-timeout N` секунд), чтобы доказать работу агента (self-report не
ground truth, KTD3).

**По умолчанию команда извлекается из `## Verification Contract` самого плана**
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
| verify-doc, work | одна доп. попытка стадии свежим узлом; для work — с условным сбросом ветки (конверт есть → нетронутая ветка, нет → reset на pre-stage SHA) |
| secret-scan | waive: принять риск и продолжить (находка/ошибка сканера в notes) |
| verify-code (P0) | waive: запись в notes, продолжение |
| вторая пауза того же гейта | только стоп: approve = стоп-с-отчётом, deny = fail |

`deny` всегда роняет прогон. Rollback ветки не автоматизирован — откатывай
ветку целевого репо руками (`git branch -D se/<...>`).

Известные особенности resume (проверено спайком U1):

- Убитый прогон резюмится `se resume <runId>`; если smithers отвечает
  `RUN_STILL_RUNNING` — heartbeat мёртвого owner'а ещё свеж, подожди 30–45 с;
  `se resume` печатает подсказку и вывод `smithers why`.
- Правка исходников workflow между запуском и resume ломает resume
  (`RESUME_METADATA_MISMATCH`) — прогон перезапускается заново.

## Фикстурные демо (AE1–AE4)

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
- **KTD12:** work-агент без allow/deny-листа инструментов
  (`bypassPermissions` — headless-коммиты требуют Bash; изоляция — worktree и
  cwd). Гонять только на доверенных задачах до dev-container-фазы.
- Self-reported P0-счётчик ревью не сверяется независимо (KTD3, принятый риск).
- USD — оценка по прайс-таблице, не биллинг.
- Бэкап `~/.claude/.smithers/` не делается — переустановка машины теряет
  историю прогонов (принято).
- Правка workflow-исходников делает in-flight прогоны нерезюмируемыми.
