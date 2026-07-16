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
| rescan (пост-approval) | waive: принять свои коммиты, добавленные во время verify-code паузы (красный секрет-скан/validate по новым коммитам в notes) |
| вторая пауза того же гейта | только стоп: approve = стоп-с-отчётом, deny = fail |

`deny` всегда роняет прогон. Rollback ветки не автоматизирован — откатывай
ветку целевого репо руками (`git branch -D se/<...>`).

Известные особенности resume (проверено спайком U1):

- Убитый прогон резюмится `se resume <runId>`; если smithers отвечает
  `RUN_STILL_RUNNING` — heartbeat мёртвого owner'а ещё свеж, подожди 30–45 с;
  `se resume` печатает подсказку и вывод `smithers why`.
- Правка исходников workflow между запуском и resume ломает resume
  (`RESUME_METADATA_MISMATCH`) — прогон перезапускается заново.

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
