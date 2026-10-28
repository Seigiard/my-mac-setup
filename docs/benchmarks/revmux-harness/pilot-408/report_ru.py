"""Build the Russian #408 pilot report draft (bare semantic HTML with render-kit markers) from metrics.json. Prose follows ASD-STE100 rules in Russian."""
import json, sys, html, collections
B = sys.argv[1]; m = json.load(open(f"{B}/metrics.json"))
pa = m["per_arm"]; arms = ["baseline", "sonnet", "terra"]; E = html.escape
AR = {"baseline": "базовое", "sonnet": "Sonnet", "terra": "Terra"}
def pct(a, b): return f"{100*a/b:.0f}%" if b else "–"
def row(cells, th=False):
    t = "th" if th else "td"; return "<tr>" + "".join(f"<{t}>{c}</{t}>" for c in cells) + "</tr>"
models = {"baseline": "opus 5.5 + gpt-6.1-sol", "sonnet": "sonnet 5.5 + gpt-6.1-sol", "terra": "opus 5.5 + gpt-6.1-terra"}
cost = [row(["Плечо", "Модели поисковиков", "Раундов", "Токенов на раунд", "Claude на раунд", "Codex на раунд", "Минут на раунд"], True)]
for a in arms:
    c = pa[a]; n = c["rounds"]
    cost.append(row([AR[a], models[a], n, f"{c['tokens']/n/1e6:.1f}M", f"{c['claude_tokens']/n/1e6:.1f}M", f"{c['codex_tokens']/n/1e6:.2f}M", f"{c['duration_ms']/n/60000:.1f}"]))
yld = [row(["Плечо", "Найдено", "из них major", "сторона Claude", "сторона Codex", "Дошло до финала", "Отброшено", "Слито", "старое / несущественное / вопрос"], True)]
for a in arms:
    c = pa[a]
    yld.append(row([AR[a], c["found"], c.get("found_major", 0), c.get("found_claude", 0), c.get("found_codex", 0), c.get("fate_kept", 0), c.get("fate_dropped", 0), c.get("fate_merged", 0), f"{c.get('fate_pre_existing',0)} / {c.get('fate_immaterial',0)} / {c.get('fate_open_question',0)}"]))
case_rows = [row(["Кейс", "Плечо", "повтор 1: найдено→финал", "повтор 2", "повтор 3"], True)]
fk = collections.defaultdict(lambda: [0, 0])
for r in m["findings"]:
    k = (r["case"], r["arm"], r["rep"]); fk[k][0] += 1; fk[k][1] += r["fate"] == "kept"
for case in sorted({r["case"] for r in m["findings"]}):
    for a in arms:
        case_rows.append(row([case, AR[a]] + [f"{fk[(case,a,i)][0]}→{fk[(case,a,i)][1]}" for i in (1, 2, 3)]))
sv = json.load(open(f"{B}/side_verdicts.json")); sp = m.get("side_pairs", {})
SP = {}
for k in sp:
    SP[k] = k
t = [row(["Плечо", "Разобрано", "валидных", "невалидных", "неясных", "валидных major", "валидных в финале", "невалидных в финале"], True)]
for a in arms:
    c = pa[a]
    t.append(row([AR[a], c.get("adjudicated", 0), c.get("verdict_valid", 0), c.get("verdict_invalid", 0), c.get("verdict_unclear", 0), c.get("valid_major", 0), c.get("valid_kept", 0), c.get("invalid_kept", 0)]))
pairs = [row(["Кандидат против базового", "только базовое", "только кандидат", "общие"], True)]
for cand in ("sonnet", "terra"):
    g = m["pairs"][cand]["aggregate"]
    pairs.append(row([AR[cand], g.get("baseline_only", 0), g.get("candidate_only", 0), g.get("shared", 0)]))
stab = [row(["Кейс", "Плечо", "валидных причин", "во всех 3 повторах", "в 2 из 3", "в 1 из 3"], True)]
for case, arms_ in m["stability"].items():
    for a in arms:
        cs = arms_.get(a, {}); cnt = collections.Counter(cs.values())
        stab.append(row([case, AR[a], len(cs), cnt.get(3, 0), cnt.get(2, 0), cnt.get(1, 0)]))
only = []
for cand in ("sonnet", "terra"):
    for case, d in m["pairs"][cand]["by_case"].items():
        for side, label in (("baseline_only", "только базовое"), ("candidate_only", "только кандидат")):
            for cause in d[side]:
                sev = sorted({r["severity"] for r in m["findings"] if r["case"] == case and r.get("cause") == cause})
                only.append(row([AR[cand], case, label, E(cause), ", ".join(sev)]))
side_t = [row(["Плечо и сторона", "Разобрано", "валидных", "невалидных", "неясных", "валидных major", "валидных в финале"], True)]
for k, c in sv.items(): side_t.append(row([E(k), c["adj"], c["valid"], c["invalid"], c["unclear"], c["valid_major"], c["valid_kept"]]))
sp_t = [row(["Пара (одни линзы, одна сторона заменена)", "только у первого", "только у второго", "общие"], True)]
for k, v in sp.items():
    g = v["aggregate"]; sp_t.append(row([E(k), g.get("a_only", 0), g.get("b_only", 0), g.get("shared", 0)]))
rounds_n = sum(pa[a]["rounds"] for a in arms)
son_pct = pct(pa['sonnet']['claude_tokens'], pa['baseline']['claude_tokens']); ter_pct = pct(pa['terra']['codex_tokens'], pa['baseline']['codex_tokens'])
invalid_kept = sum(pa[a].get('invalid_kept', 0) for a in arms)
page = f"""<!doctype html><html lang="ru"><head><title>Пилот замены моделей revmux, #408</title>
<!-- kit: head -->
<!-- kit: components -->
</head><body><main lang="ru">
<hgroup><h1>Пилот замены моделей в revmux для #408</h1><p>{rounds_n} раундов 27 октября 2026: три плеча, три кейса, три повтора. Это пилот, не решающий прогон. Он проверяет цепочку измерения и даёт размер для решающего прогона.</p></hgroup>
<nav aria-label="Содержание"><ul><li><a href="#q">Ответы</a></li><li><a href="#terms">Термины</a></li><li><a href="#setup">Условия</a></li><li><a href="#cost">Цена и время</a></li><li><a href="#yield">Выход поисковиков</a></li><li><a href="#adj">Слепая разметка</a></li><li><a href="#limits">Ограничения</a></li><li><a href="#next">Решающий прогон</a></li></ul></nav>
<h2 id="q">Ответы</h2>
<dl>
<dt>Работает ли цепочка измерения?</dt><dd>Да. Harness записал 27 раундов. Ни один раунд не деградировал. Экспорт скрыл имена моделей. Три разметчика не видели ключ. Ключ открыт после записи всех трёх файлов разметки.</dd>
<dt>Sonnet вместо Opus</dt><dd><del>Пилот не поддерживает замену.</del> Сторона Opus нашла 12 валидных причин, которые сторона Sonnet не нашла. Сторона Sonnet нашла 1 причину, которую Opus не нашёл. Контроль Opus против Opus дал 5 против 4. Разрыв 12 против 1 намного больше шума. Sonnet не нашёл ни одной валидной major-находки, Opus нашёл 17. Sonnet потратил {son_pct} токенов Opus.</dd>
<dt>Terra вместо Sol</dt><dd><mark>Вопрос открыт.</mark> Sol нашёл 9 валидных причин, которые Terra не нашла. Terra нашла 10 причин, которые Sol не нашёл. Контроль Sol против Sol дал 6 против 4. Разрыв 9 против 10 не больше шума. Пилот не может отличить Terra от Sol. Terra нашла 27 валидных major-находок, Sol нашёл 9. Terra дала 4 невалидные находки, Sol дал 0. Terra потратила {ter_pct} токенов Sol. Эту пару решает решающий прогон с заранее заданным порогом.</dd>
<dt>Насколько шумит один раунд?</dt><dd>Сторона Claude была одинаковой в базовом плече и в плече Terra. За девять раундов она нашла {pa['baseline'].get('found_claude',0)} и {pa['terra'].get('found_claude',0)} находок. Общих валидных причин было 14, уникальных 5 и 4. В базовом плече только 11 из 28 валидных причин появились во всех трёх повторах кейса. Один раунд ничего не ранжирует. Решающий прогон делает не меньше трёх повторов на кейс.</dd>
<dt>Сохраняет ли конвейер то, что разметка признала валидным?</dt><dd>За 27 раундов до финального списка дошла {invalid_kept} невалидная находка. Остальные невалидные и неясные находки конвейер слил, отбросил или переклассифицировал до финала. Синтез и проверка на Opus сработали в каждом плече.</dd>
</dl>
<h2 id="terms">Термины</h2>
<dl>
<dt>Плечо</dt><dd>Один состав моделей. В пилоте три плеча: базовое (opus 5.5 + gpt-6.1-sol), Sonnet (все агенты Claude на sonnet 5.5), Terra (все агенты Codex на gpt-6.1-terra).</dd>
<dt>Кейс</dt><dd>Одно замороженное изменение кода. Все плечи смотрят одинаковый diff.</dd>
<dt>Раунд</dt><dd>Один прогон revmux: одно плечо, один кейс, один повтор.</dd>
<dt>Сторона</dt><dd>Агенты одного поставщика внутри плеча: сторона Claude и сторона Codex.</dd>
<dt>Валидная причина</dt><dd>Дефект, который разметчик подтвердил по замороженному коду. Одну причину находят несколько находок с разными словами. Мы считаем причины, не находки.</dd>
<dt>Контроль</dt><dd>Сравнение одной модели с самой собой в двух плечах. Контроль показывает шум повторов. Настоящая разница должна быть больше контроля.</dd>
</dl>
<h2 id="setup">Условия</h2>
<dl>
<dt>Плечи</dt><dd>Профили <code>bench-baseline</code>, <code>bench-sonnet</code>, <code>bench-terra</code>. Состав: десять агентов профиля <code>dual-model</code> плюс одна группа линз <code>prose</code> на стороне Claude. Всего одиннадцать поисковиков. Синтез и проверка идут на opus:high в каждом плече. Модель <code>gpt-6-terra</code> из issue больше не существует в каталоге Codex.</dd>
<dt>Предпроверка</dt><dd>Реальные запросы с этой машины. Claude Code 2.1.308 ответил на opus и sonnet. Codex CLI 0.164.0 ответил на gpt-6.1-sol и gpt-6.1-terra. Каждый манифест записал фактическую модель, равную запрошенной.</dd>
<dt>Кейсы</dt><dd><code>issue-509</code>: my-mac-setup, shell-хуки и тесты bashunit, 3 файла, в checkout есть <code>.revmux/profile.md</code>. <code>prd-3488</code>: membranehq/platform, SDK, CLI плагина, тесты и документы, 17 файлов, без профиля. <code>r249-2</code>: my-mac-setup, расширение на TypeScript, тесты и два документа issue, 4 файла, без профиля. Каждый кейс смотрит замороженный checkout на SHA из корпуса. Текст scope и goal одинаков для всех плеч.</dd>
<dt>Порядок и бюджет</dt><dd>Один повтор за проход, три прохода. Каждый раунд стартовал только при недельной квоте Claude ниже 35%. Квота выросла с 15% до 19% за 27 раундов.</dd>
<dt>Разметка</dt><dd>Один слепой разметчик на кейс: OpenCode на gpt-5.6-terra, effort high. Разметчик читал замороженный код. Для каждой major-находки и каждой находки финального списка он записал основание и причину. Слитые и отброшенные minor-находки не разобраны. Плечи раскрыты после записи всех трёх файлов.</dd>
</dl>
<h2 id="cost">Цена и время</h2><table>{''.join(cost)}</table>
<p>Токены равны сумме счётчиков агентов из манифестов. Счётчики Claude и Codex имеют разные единицы. Сравнивайте их только внутри одного поставщика. Минуты равны времени раунда вместе с синтезом и проверкой. Параллельно работало не больше шести агентов.</p>
<h2 id="yield">Выход поисковиков и судьба находок</h2><table>{''.join(yld)}</table>
<p>«Найдено» считает каждую находку одиннадцати поисковиков. «Дошло до финала» считает находки финального списка. «Слито» означает, что синтез объединил находку с другой. «Отброшено» означает явное событие drop.</p>
<details><summary>По кейсам и повторам</summary><table>{''.join(case_rows)}</table></details>
<h2 id="adj">Слепая разметка</h2>
<h3>Валидные причины по сторонам: кандидат против базового, с контролями</h3>
<p>Каждая строка сравнивает валидные причины одной стороны за девять раундов двух плеч. Две строки контроля сравнивают одну модель с самой собой. Настоящая разница должна быть больше контроля.</p>
<table>{''.join(sp_t)}</table>
<h3>Вердикты по плечу и стороне</h3><table>{''.join(side_t)}</table>
<h3>Вердикты по плечу</h3><table>{''.join(t)}</table>
<h3>Группы причин: кандидат против базового, три повтора вместе</h3><table>{''.join(pairs)}</table>
<h3>Повторяемость валидных причин</h3><table>{''.join(stab)}</table>
<details><summary>Каждая причина, найденная только одной стороной</summary><table>{row(["Пара","Кейс","Сторона","Причина","Серьёзность"],True)}{''.join(only)}</table></details>
<h2 id="limits">Ограничения</h2>
<ul>
<li>Три кейса из двух репозиториев. Нет diff только из документов. Группа <code>prose</code> работала на коде со случайными документами.</li>
<li>Разметчик тоже модель, gpt-5.6-terra. Его вердикт равен второму слепому чтению кода. Это не оценка человека. Оценка человека есть только для <code>r249-2</code>.</li>
<li>Слитые и отброшенные minor-находки не разобраны. Линза с большим числом дубликатов не получила ни штрафа, ни кредита.</li>
<li>Счётчики токенов Codex учитывают токены рассуждения не так, как Claude. Цену сравнивайте внутри одного поставщика.</li>
<li>Синтез и проверка шли на opus в каждом плече. Финальный список плеча показывает также то, как opus обрабатывает кандидатов этого плеча.</li>
</ul>
<h2 id="next">Что нужно решающему прогону</h2>
<ul>
<li>Порог допустимой потери для каждой стороны. Порог задаётся до запуска и выводится из шума повторов выше.</li>
<li>Кейсы из всех пяти репозиториев корпуса. Хотя бы один diff из документов для агентов. Размеченные кейсы <code>r249</code> не участвуют в настройке.</li>
<li>Разметка заданной выборки слитых и отброшенных minor-находок. Проверка человеком каждого крупного расхождения.</li>
</ul>
</main>
<!-- kit: scripts -->
</body></html>"""
open(f"{B}/report-draft-ru.html", "w").write(page); print("draft written", len(page))
