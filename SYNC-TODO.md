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
- [ ] `~/.aliases`  · plain
- [ ] `~/.tmux.conf`  · plain
- [ ] `~/.config/tmux/flexoki-light.tmuxtheme`  · plain
- [ ] `~/.zshrc`  · ⚠️ TEMPLATE (`dot_zshrc.tmpl`) — merge/править шаблон
- [ ] `~/.zshenv`  · ⚠️ TEMPLATE (`dot_zshenv.tmpl`) — merge/править шаблон

### Claude
- [ ] `~/.claude.json`  · ⚠️ modify-скрипт (`modify_dot_claude.json`) — править скрипт
- [ ] `~/.claude/CLAUDE.md`  · plain
- [ ] `~/.claude/settings.json`  · plain
- [ ] `~/.claude/rules/typescript.md`  · plain
- [ ] `~/.claude/skills/react-doctor/SKILL.md`  · plain

### Editors / tools
- [ ] `~/.config/zed/keymap.json`  · plain
- [ ] `~/.config/zed/settings.json`  · plain
- [ ] `~/.config/zed/tasks.json`  · plain
- [ ] `~/.config/karabiner/karabiner.json`  · plain
- [ ] `~/.config/yazi/flavors/flexoki-light.yazi/flavor.toml`  · plain

### Repo meta
- [ ] `~/.gitignore`  · plain

## Репо впереди, не применено на хост (` M`)

Источник уже закоммичен; применится на свежей машине при `chezmoi apply`.

- [x] `~/.config/brewfiles/Brewfile`
- [x] `~/.config/brewfiles/Brewfile.macos`

## Скрипты (`R`)

- [ ] `.chezmoiscripts/install-packages.sh` — перезапустится при `apply`; не конфиг,
      проверить что повторный прогон идемпотентен и ничего не сломает.

## Сделано в этой сессии

- [x] `~/.config/ghostty/config` — native `term = xterm-ghostty` (превью картинок)
- [x] `~/Library/Application Support/elio/theme.toml` — Flexoki Light тема
- [x] `~/.config/herdr/config.toml` — rose-pine-dawn + experimental kitty graphics

## Заметки

- Перед снятием статуса быть залогиненным в 1Password (`op whoami`) — иначе
  файлы-шаблоны с `onepasswordRead` могут давать ложные расхождения. (Проверено
  2026-06-22: с `op` и без — список `MM` идентичен, ложных срабатываний нет.)
- Статус снят 2026-06-22 командой `chezmoi status`.
