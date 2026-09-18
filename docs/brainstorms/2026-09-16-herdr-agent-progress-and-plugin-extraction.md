# Herdr agent progress и выделение наших плагинов

Исследование и рекомендации, не утверждённый план миграции.

## Вывод

`herdr-agent-progress` полезен как дополнительный источник информации о задаче и как пример самостоятельного пакета. Заменять им нашу систему имён и Git-контекста не стоит: они отвечают на разные вопросы. Выделять наши плагины из dotfiles имеет смысл независимо от решения о progress.

Главное заимствование — самостоятельный lifecycle плагина и явный контракт состояния. Rust, SQLite и отдельный publisher нужны не каждому плагину.

## Основания и границы исследования

- Внешний исходник: [`eliasstravik/herdr-agent-progress`, commit `7f3a3fe`](https://github.com/eliasstravik/herdr-agent-progress/tree/7f3a3fe4f197686703749f65d48bc281caca5df8).
- Локальный исходник: `my-mac-setup`, commit `a8fad5127fd838292468e9b9da8aaa737e94f8b8`; рабочее дерево до исследования было чистым.
- Исследованы исходники, manifests, installation/compatibility docs и локальные зависимости. Внешний код и live-интеграции не запускались. Описанные автором live-проверки не являются нашими результатами.
- Ниже «предлагаю» обозначает проектное предложение, а не уже существующую возможность Herdr.

## 1. Что у нас есть сейчас

В текущем [Herdr config](../../home/private_dot_config/herdr/config.toml#L79-L110):

- Agents: native status, machine, workspace; второй ряд — имя pane и `$space_origin`.
- Spaces: workspace, `$branch`, `$git_status`.
- Процента выполнения или текущей активности задачи в этих rows нет.

[`herdr-pane-labels`](../../home/dot_local/bin/executable_herdr-pane-labels#L1273-L1635) назначает алиасы, формирует pane/tab labels, определяет Git location, публикует metadata. Events служат инвалидаторами, а итог вычисляется из полного snapshot; второй snapshot и повторная проверка цели защищают от применения устаревшего результата. Есть stale для недоступного Git location, monotonic generations и явная очистка tokens. Это уже содержательная модель согласованности, не просто форматирование строки.

Упаковка пока неполная:

```text
plugin manifest → ensure.sh
                    ↓ абсолютный пользовательский путь
             ~/.local/bin/herdr-pane-labels
                    ↓ относительные source
             ~/.local/lib/herdr-aliases.sh
             ~/.local/lib/herdr-process.sh
```

Источники: [manifest](../../home/private_dot_config/herdr/plugins/herdr-pane-labels/herdr-plugin.toml), [ensure.sh](../../home/private_dot_config/herdr/plugins/herdr-pane-labels/ensure.sh#L1-L14), [imports](../../home/dot_local/bin/executable_herdr-pane-labels#L18-L24).

Движок — 1876 строк Bash. Installation/lifecycle распределён ещё и по chezmoi before/after scripts и большой [cutover library](../../home/.chezmoitemplates/herdr-pane-labels-cutover-lib.sh). After-script дренирует текущую работу, связывает плагин, обходит sessions, делает strict sweep и проверяет daemon. Этот опыт нельзя потерять при смене упаковки: [activation flow](../../home/.chezmoiscripts/run_onchange_after_6-link-herdr-pane-labels.sh.tmpl#L36-L91).

## 2. Что добавляет внешний проект

| Вопрос | Наш текущий слой | Agent Progress |
|---|---|---|
| Кто агент? | Стабильный color-animal alias, pane/tab label | Проверяет session identity для привязки отчёта |
| Где работает? | Workspace, repository/worktree/branch, Git status | Не заменяет наш location layer |
| Работает или ждёт? | Native Herdr status | Сознательно не заменяет native status |
| Чем занят? | В текущих sidebar rows не представлено | Короткая activity от самого агента |
| Сколько сделано? | Не представлено | Приблизительный процент либо unknown |
| Свежи ли сведения? | Git-location stale при проблеме probe | Task-progress stale после 300 секунд без отчёта |

Пример дополнительной строки: `~65% · Testing changes`, позже `~65% · stale · Testing changes`. Это самооценка агента, не измерение по tool calls. Значение может уменьшаться. `100%` завершает task generation, но не доказывает успешность тестов или выполнения требований.

Источники: [instructions](https://github.com/eliasstravik/herdr-agent-progress/blob/7f3a3fe4f197686703749f65d48bc281caca5df8/instructions.md#L3-L19), [state/rendering](https://github.com/eliasstravik/herdr-agent-progress/blob/7f3a3fe4f197686703749f65d48bc281caca5df8/src/state.rs#L134-L212).

### Что взять в интерфейс sidebar

1. **Activity прежде всего, процент опционален.** «Проверяю миграцию» обычно полезнее спорной точности `65%`. У upstream уже разрешён unknown; можно начать с этого режима.
2. **Freshness отдельно от working/idle.** Давно не обновлявшийся отчёт не означает зависший процесс. Hook reminders и чтение context не должны освежать timestamp настоящего отчёта.
3. **Готовая summary плюс отдельные tokens.** Upstream публикует percent, freshness, activity и summary. Одна summary помогает узкому sidebar: процент и stale стоят перед обрезаемым хвостом activity. Раздельные tokens остаются для custom layouts. [Обоснование layout](https://github.com/eliasstravik/herdr-agent-progress/blob/7f3a3fe4f197686703749f65d48bc281caca5df8/src/setup.rs#L114-L123).
4. **Добавочный независимый publisher.** Наш `location-sync` продолжает владеть своими полями, progress — только `agent_progress_*`. Это уменьшает связанность и даёт отключать progress отдельно.

Возможный макет, не проверенный live:

```text
●  workspace
o:blue-fox · repository
~65% · Testing changes
```

Нужно оценить цену третьей строки при большом числе агентов. Альтернатива внутри того же контракта — activity без процента. Не следует ради progress терять стабильное имя, machine или workspace context.

### Ограничение, важное именно для нас

Реализованы Claude Code и Codex. OpenCode и Pi не имеют готовых adapters. Встроенная проверка identity допускает только `claude | codex`; печать инструкции сама по себе это не обходит. Поэтому установка не даст одинаковый результат всем нашим агентам.

[Compatibility matrix](https://github.com/eliasstravik/herdr-agent-progress/blob/7f3a3fe4f197686703749f65d48bc281caca5df8/compatibility.md#L5-L49), [identity implementation](https://github.com/eliasstravik/herdr-agent-progress/blob/7f3a3fe4f197686703749f65d48bc281caca5df8/src/runtime.rs#L99-L150).

Практический путь: ограниченный Claude pilot, затем решить, оправдывает ли полезность activity поддержку OpenCode/Pi. Для общей реализации сначала предпочтительнее вклад в upstream, чем второй независимый progress engine.

## 3. Самые полезные идеи организации кода

### Самостоятельный пакет и явный lifecycle

У upstream в одном репозитории находятся executable, canonical instructions, tests, docs и `herdr-plugin.toml`. Manifest описывает build/startup и actions `start`, `stop`, `configure`, `activate`, `doctor`, `unconfigure`. Сборка — `cargo build --release --locked`.

[Manifest](https://github.com/eliasstravik/herdr-agent-progress/blob/7f3a3fe4f197686703749f65d48bc281caca5df8/herdr-plugin.toml#L1-L48).

У нас manifests уже есть. Заимствование — довести пакет до автономности: установка из пустого home не должна требовать раскладки `my-mac-setup/home`, скрытых shell libraries и chezmoi-specific hooks для обычного запуска.

### Разделение по ответственности

Upstream разделяет CLI orchestration (`main.rs`), Herdr/process adapter (`runtime.rs`), состояние (`state.rs`), agent hooks (`hooks.rs`), публикацию (`publisher.rs`) и настройку (`setup.rs`). Это не универсальный SDK; это один application с внутренними модулями.

Для нашего pane-labels предлагаю похожие внутренние модули, сохраняя небольшой внешний interface:

```text
herdr-pane-labels/
  herdr-plugin.toml
  bin/                  # launcher, lifecycle и diagnostics
  lib/                  # snapshot/identity, aliases, location, reconcile, publish
  tests/                # поведение пакета и lifecycle
  docs/                 # metadata contract, support, installation
  examples/             # sidebar configuration
```

Имена и файловая раскладка иллюстративны. Главная проверка: consumer знает команды и контракт metadata, а не порядок source-файлов, lock directories и внутренний формат journal. Перенос в отдельный репозиторий не требует одновременно переписывать Bash на Rust.

### Identity, task generation и presentation — разные вещи

У upstream binding связан с endpoint identity, terminal, native agent session, PID и временем старта. `begin --expected-task` использует compare-and-swap; `clear` оставляет tombstone; completed generation не принимает новые reports. Sequence резервируется до внешней отправки metadata.

[Identity](https://github.com/eliasstravik/herdr-agent-progress/blob/7f3a3fe4f197686703749f65d48bc281caca5df8/src/runtime.rs#L99-L226), [state transitions](https://github.com/eliasstravik/herdr-agent-progress/blob/7f3a3fe4f197686703749f65d48bc281caca5df8/src/state.rs#L75-L159), [publication](https://github.com/eliasstravik/herdr-agent-progress/blob/7f3a3fe4f197686703749f65d48bc281caca5df8/src/publisher.rs#L122-L198).

Для нашего snapshot reconciler не нужна task state machine: он восстанавливает наблюдаемую действительность. Но при добавлении агентских отчётов generation нужна, иначе запоздавший report способен записаться в следующую задачу. Наши существующие revalidation/generation safeguards следует сохранить, а не считать отсутствующими из-за другой реализации.

### Стабильная точка запуска

Upstream устанавливает launcher вне checkout и копирует binary в plugin config directory. Это полезно для hooks, которые переживают обновление пакета. Конкретное хранение binary рядом с config необязательно повторять: важен стабильный interface запуска и контролируемая замена работающего процесса.

[Launcher и применение edits](https://github.com/eliasstravik/herdr-agent-progress/blob/7f3a3fe4f197686703749f65d48bc281caca5df8/src/setup.rs#L377-L448).

## 4. Что не стоит переносить буквально

- **Два владельца config.** Upstream `configure` правит живые Claude/Codex и Herdr config, хранит ownership journal, отказывается от symlink paths. В нашем setup эти конфиги принадлежат chezmoi. Для нас плагин должен предоставлять документированные snippets/параметры и read-only diagnostics; персональные hooks/rows остаются в source tree dotfiles. Standalone configure может быть отдельным opt-in режимом для других пользователей. [Config editing](https://github.com/eliasstravik/herdr-agent-progress/blob/7f3a3fe4f197686703749f65d48bc281caca5df8/src/setup.rs#L76-L112).
- **Обещание универсального resume.** Восстановление task ищется по тому же endpoint и terminal; native session не является глобальным ключом. Новый terminal или новая socket identity не получат старую task автоматически. [Bootstrap](https://github.com/eliasstravik/herdr-agent-progress/blob/7f3a3fe4f197686703749f65d48bc281caca5df8/src/state.rs#L75-L96).
- **Тяжёлый publisher для каждого плагина.** SQLite/WAL, polling и process identity оправданы конкурентными task reports. Для stateless notification hook это лишнее.
- **Doctor как перечень путей.** Upstream doctor не доказывает, что hooks загружены и reports доходят. Нам полезнее проверять registration, dependency availability, конкретный endpoint и последний успешный publish; live write-probe выделять в явную команду. [Doctor](https://github.com/eliasstravik/herdr-agent-progress/blob/7f3a3fe4f197686703749f65d48bc281caca5df8/src/main.rs#L119-L129).
- **Внутренний registry как стабильный interface.** Upstream читает `plugins.json`; где Herdr предоставляет публичные команды, лучше использовать их. [Registry lookup](https://github.com/eliasstravik/herdr-agent-progress/blob/7f3a3fe4f197686703749f65d48bc281caca5df8/src/runtime.rs#L277-L297).
- **Незавершённую release-модель.** В проверенном tree нет GitHub Actions; на момент API-запроса tags/releases пусты. Upgrade требует stop в каждой session, reinstall и configure. Это полезный lifecycle skeleton, но не готовый стандарт бесшовных обновлений. [Upgrade](https://github.com/eliasstravik/herdr-agent-progress/blob/7f3a3fe4f197686703749f65d48bc281caca5df8/docs/getting-started.md#L95-L126).

## 5. Какие наши репозитории выделять

Критерий: один самостоятельно устанавливаемый плагин — один репозиторий; общий framework заранее не нужен.

| Кандидат | Что переезжает | Что остаётся в dotfiles | Особенность |
|---|---|---|---|
| `herdr-focus-notify` | manifest, `notify.py`, tests/docs | terminal choice, toast policy, установка terminal-notifier | Самый узкий первый extraction; текущий Ghostty default превратить в явно документированную настройку |
| `herdr-caffeinate` | manifest, shell implementation, lifecycle tests | включение и персональные настройки | Уже использует plugin-relative `lib.sh`; есть собственное состояние/process lifecycle |
| `herdr-command-palette` | Python engine, actions, manifest, validators/tests | глобальные commands, keybindings, пользовательские shortcuts | Большой выигрыш в объёме; готовый config interface, но зависимости Python/fzf/lazygit нужно описать явно |
| `herdr-worktree-setup` | `setup.ts`, manifest, tests/docs | repository-keyed copy/steps/fresh-base policy | Уже читает `$HERDR_PLUGIN_CONFIG_DIR`; marker связан с worktree-identity |
| `herdr-pane-labels` | reconciler, private libraries, manifest, lifecycle и tests | sidebar rows, выбранные параметры и версия пакета | Самый сложный перенос: alias consumers, работающие daemons, поколения и metadata ownership |

Основания: [notify config](../../home/private_dot_config/herdr/plugins/herdr-focus-notify/notify.py#L33-L107), [caffeinate import](../../home/private_dot_config/herdr/plugins/herdr-caffeinate/reconcile.sh), [palette config interface](../../home/private_dot_config/herdr/plugins/command-palette/README.md#L42-L79), [worktree config interface](https://github.com/Seigiard/herdr-worktree-setup/blob/70048c616979719aa592df36f37ec076227b2ac8/README.md#configuration).

### Две реальные зависимости, которые мешают простому переносу папок

**Alias contract.** `herdr-child` и `herdr-peer-alias` используют ту же `herdr-aliases.sh`, что и pane-labels. Launcher выбирает имя из этого пула, reconciler проверяет принадлежность пулу. Независимые копии библиотеки могут разойтись.

Предлагаю одного владельца alias policy в пакете pane-labels и маленький публичный CLI для его consumers. Сохранить совместимый launcher `herdr-peer-alias`; для child определить нужный interface получения candidates/выбора имени и семантику занятых/reserved names. Текущий CLI выбирает свободное имя, но не создаёт атомарную reservation — будущий contract не должен обещать обратное. `herdr-child` переводится на этот interface до удаления общей библиотеки. Общую process utility можно упаковать приватно с явной версией; не создавать отдельный runtime-framework ради нескольких helpers.

[Child imports](../../home/dot_local/bin/executable_herdr-child#L9-L24), [child allocation](../../home/dot_local/lib/herdr-child-launch.sh#L91-L121), [peer interface](../../home/dot_local/bin/executable_herdr-peer-alias#L1-L19).

**Worktree marker contract.** Setup пишет `herdr-generated-worktree`, а worktree-identity использует marker как разрешение на переименование. Это межпакетный contract, который нужно документировать и проверять совместно. Agent adapters worktree-identity должны переезжать вместе со своим engine при его отдельном extraction. [Ownership](../../docs/herdr-worktrees.md#L18-L29).

`herdr-child` — отдельный инструмент оркестрации, не просто sidebar plugin. Его репозиторий можно выделить позже с собственными CLI и supervision contracts, не приклеивая его lifecycle к labels.

## 6. Кто чем владеет после выделения

```text
my-mac-setup
  выбор плагинов и проверенных версий
  персональные settings, sidebar rows, keybindings, commands
  repository-specific worktree policy
  тонкая установка и deployment smoke coverage

plugin repository
  implementation и приватные зависимости
  manifest, lifecycle, compatibility/docs
  schema состояния и upgrade compatibility
  behavioral tests, CI и releases

runtime directories
  plugin-owned state/cache/logs
  не являются chezmoi source
```

У нас уже есть [GitHub-plugin installer](../../home/.chezmoiscripts/run_onchange_after_7-install-herdr-github-plugins.sh.tmpl#L56-L74), сейчас для `dio16/herdr-auto-update`. Это естественное место тонкой интеграции после extraction. Но запись `owner/repo` и lock dependencies не фиксируют версию самого plugin source: перед обещанием воспроизводимости надо проверить способ установки exact ref в используемой версии Herdr и выбрать поддерживаемую release policy. Автообновление — отдельный осознанный режим.

Не следует оставлять в dotfiles обычный lifecycle нового пакета под видом install script. Временный переход со старой chezmoi-managed раскладки — ответственность этой миграции; последующие stop/start/upgrade — ответственность пакета.

## 7. Рекомендуемая последовательность

1. **Вынести focus-notify как пробный самостоятельный пакет.** Получить минимальный стандарт manifest, config interface, clean-home installation, CI и release. Сохранить plugin ID, чтобы пользовательские keybindings/actions не мигрировали без необходимости.
2. **Вынести command-palette.** Это даст заметное уменьшение application code в dotfiles, используя уже отделённый user config. Caffeinate можно перенести по тому же образцу.
3. **Подготовить contract aliases и упаковать pane-labels.** Сначала закрыть зависимость child/peer, затем переносить runtime. Сохранить единственного writer labels и поведение generations/revalidation. Не совмещать extraction, смену языка и добавление progress.
4. **Выделить worktree-setup с marker contract.** Держать user/project policy в dotfiles; worktree-identity рассматривать как отдельный пакет с adapters.
5. **Progress оценивать отдельно.** Claude pilot на реальных задачах: полезность activity, лишние tool calls/reminders, чтение узкого sidebar, stale после долгих команд, цена дополнительной строки. Затем решение об upstream OpenCode/Pi adapters.

Для каждого extraction переносить behavioral coverage к владельцу implementation, а в dotfiles оставлять deployment contract. Сценарии принятия: установка без этого checkout, конфиг остаётся пользовательским, обновление при работающей session, удаление, корректные metadata после restart, заявленная OS/client compatibility. Для pane-labels дополнительно перенос pane и отложенная публикация не должны переименовать новую цель старым именем.

Это критерии будущей реализации, не результаты выполненных тестов. В этом исследовании добавлен только документ; runtime и managed configs не менялись.
