# Config sync tracker

## Что делаем и зачем

Этот репозиторий — **chezmoi-управляемый** dotfiles-сетап (см. `CLAUDE.md`). За время
работы на живой машине накопились локальные правки конфигов, которых **нет в репо**
(`home/`). Цель: пройтись по расходящимся файлам, сверить, и привести источник в
соответствие с живой версией (или наоборот), чтобы `chezmoi apply` на свежей машине
давал актуальный сетап.

Этот файл — трекер прогресса. Любой агент может подхватить: бери незакрытый пункт
из чеклиста ниже, выполни по процедуре, отметь `[x]`.

## ⚠️ Правила работы (обязательно)

- **Только пошагово, по одному файлу.** Никакой автономной/пакетной работы.
- Для каждого файла: показать `chezmoi diff`, предложить конкретное изменение и
  направление синка → **дождаться явного согласования пользователя** → только потом
  применять.
- Не трогать следующий файл, пока текущий не согласован и не закрыт.
- Не коммитить без явной просьбы пользователя.

## Контекст репо (нужно знать перед работой)

- Источник конфигов: `home/` (`.chezmoiroot = home`), файлы маппятся в `~/`.
- **НЕ запускать `chezmoi apply`/`chezmoi init` на хосте** — только `make test-local`
  (diff) или Docker. Правки вносить в **источник** `home/`, не в живой файл.
- Расхождения снимаются: `chezmoi status` (коды: `MM` = живое и репо разошлись;
  ` M` = репо впереди, на хост не применено; `R` = run-скрипт перезапустится).
- Diff по файлу: `chezmoi diff ~/path`.

## Процедура синка (по типу источника!)

Сначала определи тип источника: `chezmoi source-path ~/path` → смотри basename.

1. **plain** (`dot_foo`, `foo.json`) — сверить `chezmoi diff ~/path`, решить направление.
   Затянуть живое → репо: `chezmoi add ~/path`. Накатить репо → живое НЕ на хосте.
2. **TEMPLATE** (`*.tmpl`) — ⚠️ **НЕ `chezmoi add`** (затрёт шаблон и впечёт секреты!).
   Использовать `chezmoi merge ~/path` или править исходный `.tmpl` руками.
3. **modify-скрипт** (`modify_*`) — ⚠️ **НЕ `chezmoi add`**. Логика в `modify_`-скрипте,
   который читает текущий файл из stdin и выдаёт модифицированный. Править скрипт.

После синка: `chezmoi diff ~/path` должен стать пустым → коммит (стиль репо:
заглавный imperative, без conventional-префиксов; см. `git log`).

## Tracker — расходятся (`MM`), правил локально, в репо нет

### Shell
- [x] `~/.aliases`  · plain → live→репо (`chezmoi add`), dev_auto+gpmain/gmmain
- [x] `~/.tmux.conf`  · plain → live→репо (`chezmoi add`): tmux-256color+terminal-features, вернул source-file
- [x] `~/.config/tmux/flexoki-light.tmuxtheme`  · plain → `chezmoi add --follow`: вшил богатую тему (live = симлинк на неуправляемый alacritty-tmux). Остаточный diff symlink↔real-file — намеренно, источник self-contained
- [x] `~/.zshrc`  · TEMPLATE → убрал peon-ping из шаблона; alacritty word-arrows + meridian overrides оставлены live-only (эксперименты, в репо не тянем)
- [x] `~/.zshenv`  · TEMPLATE → добавил AGENT_BROWSER_EXECUTABLE_PATH под `{{ if .is_darwin }}`; MEMBRANE(plaintext-секрет!)/AMP/cargo оставлены live-only, не тянем

### Claude
- [x] `~/.claude.json`  · modify-скрипт → veche удалён из live (`claude mcp remove veche`), в репо-скрипт не добавляли. Источник не менялся; остаток diff — рантайм-каша usageCount/lastUsedAt (неустранимо)
- [x] `~/.claude/CLAUDE.md`  · plain → live→репо (`chezmoi add`), 222 стр. Репо-рестрактур (121 стр) + принципы Assumptions/Full-completion/superpowers сознательно отброшены
- [x] `~/.claude/settings.json`  · plain → live→репо (`chezmoi add`): effortLevel=medium, втянул herdr SessionStart-хук. Источник переименован settings.json→private_settings.json (live 0600)
- [x] `~/.claude/rules/typescript.md`  · plain → РЕПО ВПЕРЕДИ (расширенные React/Hooks секции со скиллами). Источник не трогаем, доедет на apply
- [x] `~/.claude/skills/react-doctor/SKILL.md`  · plain → исправил флаги на актуальные CLI (`--diff/--offline/--no-ami` → `--scope files --no-telemetry -y`) в репо И live

### Editors / tools
- [x] `~/.config/zed/keymap.json`  · plain → live→репо (`chezmoi add`), донастроенные биндинги + CSI-u shift-enter
- [x] `~/.config/zed/settings.json`  · plain → live→репо целиком (`chezmoi add`): tsgo (не vtsls), все live-префы, agent_servers codex/pi/opencode
- [x] `~/.config/zed/tasks.json`  · plain → @um/@mm на gpmain/gmmain (live), @as/@alg (alacritty-session) удалены из live+репо. `chezmoi add`
- [x] `~/.config/karabiner/karabiner.json`  · plain → live→репо (`chezmoi add`), private_karabiner.json (0600). **Решено: json = единственный источник.** goku убран (install-скрипт + Brewfile.macos), `karabiner.edn` удалён (источник+живой) как мёртвый балласт. Live goku-бинарь ещё установлен — опц. `brew uninstall goku && brew untap yqrashawn/goku`
- [x] `~/.config/yazi/flavors/flexoki-light.yazi/flavor.toml`  · plain → live→репо (`chezmoi add`): ключ `url` (не `name`), yazi-схему фиксили недавно

### Repo meta
- [x] `~/.gitignore`  · plain → РЕПО ВПЕРЕДИ/корректнее (`Icon?` vs живой `Icon`). Источник не трогаем, доедет на apply

## Репо впереди, не применено на хост (` M`)

Источник уже закоммичен; применится на свежей машине при `chezmoi apply`.

- [x] `~/.config/brewfiles/Brewfile`
- [x] `~/.config/brewfiles/Brewfile.macos`

## Скрипты (`R`)

- [x] `.chezmoiscripts/install-packages.sh` — идемпотентен (всё под guards: `command -v`,
      `[[ ! -d ]]`, `|| true`, `brew bundle` без `--cleanup`). **Убран goku-шаг** — он
      перезаписывал бы управляемый karabiner.json из edn. Теперь повторный прогон безопасен.

## Сделано в этой сессии

- [x] `~/.config/ghostty/config` — native `term = xterm-ghostty` (превью картинок)
- [x] `~/Library/Application Support/elio/theme.toml` — Flexoki Light тема
- [x] `~/.config/herdr/config.toml` — rose-pine-dawn + experimental kitty graphics

## Заметки

- Перед снятием статуса быть залогиненным в 1Password (`op whoami`) — иначе
  файлы-шаблоны с `onepasswordRead` могут давать ложные расхождения. (Проверено
  2026-06-22: с `op` и без — список `MM` идентичен, ложных срабатываний нет.)
- Статус снят 2026-06-22 командой `chezmoi status`.
