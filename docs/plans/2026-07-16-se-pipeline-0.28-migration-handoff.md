# Handoff — se-pipeline миграция на Smithers 0.28 (U9)

**Дата:** 2026-07-16. **Для:** следующего агента, продолжающего U9.
**Канонический план:** `docs/plans/2026-07-14-001-feat-smithers-pipeline-plan.md` — читай **KTD14** (решения 0.28), **U9** (юнит миграции + подсекция «Прогресс/Результаты»), **KTD5** (резолюция git-only). Оба файла gitignored.
**Память:** `~/.claude/projects/-Users-andrew-b-Projects-my-mac-setup/memory/{se-pipeline-project,smithers-0-27-quirks}.md`.

## TL;DR состояния

- **Код U9 готов и проверен на unit/git уровне** (`bun test` 69/0, транспиляция OK). **Не закоммичено.**
- **Full-pipeline end-to-end НЕ проверен** — жёсткий внешний блокер: **org-level Claude `org_level_disabled`** (не код, не 0.28). См. раздел «Блокер».
- Решение «оставить 0.28 или откатить на 0.27» **отложено** — ждём разблокировки org-Claude, чтобы прогнать end-to-end.

## Что сделано (файлы, все в `home/private_dot_claude/dot_smithers/`)

| Файл | Изменение |
|---|---|
| `package.json` | `smithers-orchestrator` 0.27.0→**0.28.0**; `trustedDependencies:[@smithers-orchestrator/jj-darwin-arm64]` (jj-бинарь доверен) |
| `workflows/lib/gates.ts` | `workGate` proof на **tree-хэш** (`WorkGateInput{raw,baseTree,headTree,validateExitCode}`); снят `headSha`/`final_commit_sha==HEAD`; `final_commit_sha`→advisory |
| `workflows/lib/gates.test.ts` | тесты workGate под новый контракт |
| `workflows/lib/staging.ts` | +`commitWorkGuarded(worktreePath,msg):bool` (коммит только грязного дерева), +`treeHash(cwd,ref='HEAD')` |
| `workflows/lib/staging.test.ts` | +тесты идемпотентности `commitWorkGuarded` (KTD5 acceptance без Claude) + `treeHash` |
| `workflows/se-pipeline.tsx` | work-промпт НЕ просит коммит; `workGateFn` → `commitWorkGuarded`+`treeHash`; extra-prep reset чистит грязное дерево; **константы моделей** `WORK_MODEL=claude-opus-4-8`/fb `claude-sonnet-5`, `REVIEW_MODEL=claude-sonnet-5`/fb `claude-haiku-4-5` |
| `workflows/se-doc-review.tsx` | claudeAgent `model:claude-sonnet-5`, `fallbackModel:claude-haiku-4-5` (ОБЩИЙ донор — юзается и `/se-doc-review`) |

## Ключевая механика KTD5-фикса (git-only, БЕЗ jj/`<Worktree>`)

Дубль коммита на kill-resume устранён: **агент больше не коммитит** (ce-work без явного запроса не коммитит — вердикт U1/KTD13), коммит делает **одна мемоизируемая gate-задача** через `commitWorkGuarded` (коммит только если `git status --porcelain` непусто). Kill-после-commit/до-персиста → resume видит чистое дерево → guard пропускает → дубля нет. Proof-of-work = `treeHash(base) ≠ treeHash(HEAD)` (устойчиво к git-состоянию). `<Worktree>`/jj отвергнуты как высокорисковый рерайт при непроверенной land-идемпотентности (см. U9 Батч 3).

## БЛОКЕР: org-level Claude `org_level_disabled`

> **UPDATE 2026-07-16 (расследовано, диагноз ниже НЕВЕРЕН):** это НЕ ограничение Anthropic и НЕ исчерпание лимита. Это **регрессия smithers 0.28** — `ClaudeCodeAgent.js` (условие `status==="rejected" || overageStatus==="rejected"`, коммит upstream `afc636ab`) трактует `overageStatus:"rejected"` как исчерпанный лимит. На Max-аккаунте БЕЗ включённых usage credits Claude CLI шлёт `rate_limit_event{status:"allowed", overageStatus:"rejected", overageDisabledReason:"org_level_disabled"}` на КАЖДЫЙ запрос → smithers роняет каждый claude-лег через ~6с, даже если сессия успешна. В 0.27 этой ветки нет — потому AE1 e2e проходил. Доказательство: `claude -p "Reply with exactly: PROBE_OK" --output-format stream-json --verbose | rg rate_limit` → `status:"allowed"` + `overageStatus:"rejected"` в успешном прогоне. **ПОФИКШЕНО 2026-07-16**: `bun patch @smithers-orchestrator/agents@0.28.0` (см. `patches/`, `patchedDependencies` в package.json) — ClaudeCodeAgent.js `rejected = status === "rejected"`, BaseCliAgent.js без 120с-кэпа и с ужесточённым QUOTA_PATTERNS. Верифицировано: bun test 69/0; smoke `run-1784198676339` finished, гейты verify-doc/work/secret-scan/verify-code green, один gate-коммит (KTD5). Осталось из шага 1: kill-resume KTD5 end-to-end. Детали: memory `smithers-org-level-disabled-bug`.

Full-pipeline smoke падает на verify-doc → `review-claude`:
```
Claude five_hour usage limit exceeded (rate_limit_event rejected: org_level_disabled)..
org-level concurrency throttle; retrying in 120s
```
Диагностика (проведена, не повторяй):
- auth = **Claude Max-подписка** (claude.ai OAuth, firstParty), НЕ API-ключ (`ANTHROPIC_API_KEY` unset). API free-tier 5 RPM (console) — **не наш путь**.
- **model-agnostic**: Sonnet 5 бьётся так же; `fallbackModel`→Haiku НЕ спасает (org-wide).
- **не** контенция с интерактивной Claude Code сессией (во время прогона Claude звал только пайплайн).
- короткий `claude -p "..."` **проходит**; длинная агентная сессия — нет. Личная сессия 26%/5h не исчерпана.
- **Вывод:** org-ограничение Anthropic на headless-агентный Claude. **Из кода нечинимо.** Решается на аккаунте/org: console.anthropic.com (Claude Code / org settings) или Anthropic support.
- **Проверить, снят ли блок:** `timeout 60 claude -p "Reply with exactly: PROBE_OK"` — но это одиночный probe (всегда проходит). Реальная проверка — только прогнать пайплайн (см. ниже) и посмотреть, не появился ли `org_level_disabled` в логе.

**НЕ долби перезапусками** — 5 прогонов подтвердили стену. Возобновлять end-to-end только после сигнала оператора, что org-доступ решён.

## Как проверять / запускать

```bash
SRC=~/Projects/my-mac-setup/home/private_dot_claude/dot_smithers
cd "$SRC"
bun test                         # 69/0 ожидается
bun build workflows/se-pipeline.tsx --target=bun --outfile=/tmp/x.js   # транспиляция
cd ~/Projects/my-mac-setup && make lint   # SC2034 UNDERLINE — предсуществующий, игнор

# Full-pipeline smoke (тратит Claude; блокирован org-Claude сейчас):
FIXTURE=$(bash ~/Projects/my-mac-setup/tests/fixtures/make-pipeline-fixture.sh)
cd "$SRC"
INPUT=$(jq -cn --arg p "$FIXTURE/docs/plans/fixture-reverse-plan.md" '{planPath:$p,until:"branch",smoke:true,validateCmd:"true"}')
PIPELINE_REPO="$FIXTURE" DOC_REVIEW_REPO="$FIXTURE" ./node_modules/.bin/smithers up workflows/se-pipeline.tsx --detach --input "$INPUT"
# наблюдать: ./node_modules/.bin/smithers inspect <runId> --format json | jq '.run.status'
#           sqlite3 smithers.db "SELECT node_id,state FROM gate_verdict WHERE run_id='<runId>'"
```

## Гоча (проверено болью)

- **Лог прогона:** `workflows/<runId>.log` — `<runId>` УЖЕ содержит `run-`. НЕ пиши `run-$RID.log` (двойной `run-` → файла нет).
- **child-runId с двоеточиями** (`run-…:child:verify-doc:0`) CLI `output`/`tree`/`inspect` частично отвергают (`InvalidRunId`). Читай child через `sqlite3 smithers.db` напрямую.
- **smithers.db схема 0.28:** `_smithers_events(run_id,seq,timestamp_ms,type,payload_json)` — НЕТ колонки `node_id`. Output-таблицы (`doc_review`,`gate_verdict`,`agent_report`,…) имеют `(run_id,node_id,iteration,<поля-схемы>)`, НЕ `data_json`.
- **child-статус `waiting-quota`** = агент запаркован на квоте (не крашнут).
- **правка workflow-исходников ломает resume** in-flight прогонов (RESUME_METADATA_MISMATCH) — мигрируй при отсутствии живых прогонов.
- **НЕ коммить без явной команды оператора.** **НЕ `chezmoi apply` на хосте** (см. CLAUDE.md). Прогоны идут из source-дира, не из рантайма `~/.claude/.smithers` (там старые 0.27-доноры; деплой — секция U-DEPLOY плана).
- модель-ID: `claude-opus-4-8`, `claude-sonnet-5`, `claude-haiku-4-5`, `claude-fable-5`. `ClaudeCodeAgent` принимает `model?`/`fallbackModel?`. `apiKey?` есть, но **API не подключаем** (решение оператора — только Max-подписка).

## Сделано (2026-07-16, коммиты 0198794 / 4de305c / b9d50b4 / d7d8fd6)

- ~~Блокер org-Claude~~ — баг smithers 0.28, пофикшен bun-патчем (см. «Блокер»); smoke `run-1784198676339` green (4 гейта, один gate-коммит).
- ~~KTD5 e2e~~ — `run-1784204259645`: kill в окне commit→persist → force-resume → finished, РОВНО ОДИН коммит, дубля нет.
- ~~Батч 4~~ — `lib/cost.ts` на официальных `estimateCostUsd`/`modelTokenPrices` (префикс-срез, sonnet-fallback вместо $0, cacheWrite учтён); AE1: $0.83 vs $0.75 старым — порядок сходится.
- ~~Раннбук~~ — `docs/se-pipeline.md` догнал 0.28 (патч, KTD5 закрыт, модели, прайсинг).
- ~~Развилка 0.28-vs-0.27~~ — закрыта в пользу 0.28 (end-to-end подтверждён).
- ~~Тех-долг: Subflow-типы~~ — каст `WorkflowDefinition<unknown>` с обоснованием (se-pipeline.tsx, импорт-блок). **НЕ закоммичено.**

## Следующие шаги (СТРОГО в этом порядке — каждый шаг разблокирует следующий)

0. **Закоммитить Subflow-каст** (незакоммиченный хвост тех-долга, см. выше).
1. ~~U-DEPLOY + push~~ **ЗАВЕРШЁН 2026-07-16** (оператор применил scoped apply + `~/.zshenv`; runtime deps доставлены, патч в рантайме проверен; `unset SE_SMITHERS_DIR`/перезапуск терминала — переменная наследуется от старых процессов). Runtime `se list` чист — история прогонов осталась в source-дире (принято). Гоча на будущее: **scoped `chezmoi apply <target>` НЕ запускает `.chezmoiscripts`** — bun-install-хук отрабатывает только на полном apply. Детали подготовки: Сделано: (а) main запушен (0198794…7c350a4); (б) chezmoi-source клон `~/.local/share/chezmoi` синкнут (7c350a4), `dot_smithers` в нём появился; (в) решение по модели — вариант (а) плана: chezmoi управляет ТОЛЬКО source-файлами, стейт исключён в `.chezmoiignore` (зеркало dot_smithers/.gitignore; заодно починил зависавший `make test-local` — 12с вместо таймаута), deps ставит новый `run_onchange_after_4-install-smithers-deps.sh.tmpl` (`bun install --frozen-lockfile` в `~/.claude/.smithers` по хэшу package.json+bun.lock); (г) apply-превью проверено `chezmoi status`: M package.json/bun.lock, A patches/workflows/bin, стейт не тронут; симлинк `~/.local/bin/se` перенацелится на рантайм, `~/.zshenv` managed → TEMP-блок `SE_SMITHERS_DIR` уйдёт сам; (д) тесты 54/54 bats, CI test-ubuntu+lint green (test-macos флак — checksum каска telegram, не наше). **Оператору:** `chezmoi apply -v` (или скоупно `chezmoi apply ~/.claude/.smithers ~/.local/bin/se`), затем в НОВОМ шелле `se list` и прогнать `/se-code-review` на мелочи — доноры рантайма обновятся до 0.28-версий. Заметка: `smithers.db` рантайма пустой — история прогонов остаётся в source-дире, `se list` из рантайма начнёт с чистого листа.
2. ~~Тулинг для unattended F3~~ **СДЕЛАНО 2026-07-16** (коммиты 124bc17, 41a6771):
   a. `se list --json` ({runs, summaries}) + `se show <runId> [--json]` (статус+вердикт+reportDir+файлы; child-id деградирует в run:null); человеческий `se list` перестал печатать toon-простыню (рендер из `ps --format json`, children свёрнуты). bats 59/59.
   b. process-group kill в `runValidateCmd`: spawnSync НЕ умеет detached → врапер с `set -m` (джоба в своей группе) + trap `kill -KILL -- -$!`; фон-под-wait обязателен (bash откладывает trap при foreground-child). Тест с внуком 76/0.
   Для рантайма: `chezmoi apply ~/.claude/.smithers` после pull клона (bin/se + envelopes.ts — скрипты не нужны).
3. **F3 — сравнительная фаза** (главная приёмка): рабочие задачи integration.app, ручной трек vs `se pipeline <план> --until=branch`; чек-лист `--until=pr` в раннбуке (≥3 прогонов без P0, чистый секрет-скан, resume без потерь, приемлемая дельта стоимости). Наблюдения — в журнал фазы канонического плана.
4. **Батч 5 (опц., ПОСЛЕ F3)** — `ctx.prove`/`ProofBinding` для gate-0 (KTD7) + approval-rescan ручных коммитов оператора во время verify-code-паузы. До F3 не нужен: ценность появляется на недоверенных/долгих прогонах.
5. **Фоново, без порядка:** следить за upstream smithersai/smithers#1342 — при фиксе снять локальный патч (`patches/`); решить судьбу `docs/ideation/*.html` (закоммитить или в .gitignore).

Зависимости одной строкой: **коммит хвоста → деплой/push → тулинг → F3 → (опц.) Батч 5**; п.5 — параллельно всему.
