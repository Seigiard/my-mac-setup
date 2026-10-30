"""Build the Russian #576 holdout report draft (bare semantic HTML with render-kit markers) from metrics.json and verdict_ru.json. Prose follows ASD-STE100 rules in Russian."""
import json, sys, html, collections, datetime
B = sys.argv[1]; m = json.load(open(f"{B}/metrics.json")); V = json.load(open(f"{B}/verdict_ru.json"))
pa = m["per_arm"]; arms = ["baseline", "terra"]; G = m["gates"]
E = html.escape
AR = {"baseline": "базовое", "terra": "Terra"}
def pct(a, b): return f"{100*a/b:.0f}%" if b else "–"
def row(cells, th=False):
    t = "th" if th else "td"; return "<tr>" + "".join(f"<{t}>{c}</{t}>" for c in cells) + "</tr>"
models = {"baseline": "opus 5.5 + gpt-6.1-sol", "terra": "opus 5.5 + gpt-6.1-terra"}
cost = [row(["Плечо", "Модели поисковиков", "Раундов", "Деградировало", "Токенов на раунд", "Claude на раунд", "Codex на раунд", "Минут на раунд"], True)]
for a in arms:
    c = pa[a]; n = c["rounds"]
    cost.append(row([AR[a], models[a], n, c.get("degraded", 0), f"{c['tokens']/n/1e6:.1f}M", f"{c['claude_tokens']/n/1e6:.1f}M", f"{c['codex_tokens']/n/1e6:.2f}M", f"{c['duration_ms']/n/60000:.1f}"]))
yld = [row(["Плечо", "Найдено", "major", "сторона Claude", "сторона Codex", "Дошло до финала", "Отброшено", "Слито", "старое / несущественное / вопрос"], True)]
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
sp = m["side_pairs"]; sv = m["side_verdicts"]
SP = {"codex: sol (baseline) vs terra": "Codex: sol (базовое) против terra", "control, claude: opus (baseline) vs opus (terra arm)": "контроль, Claude: opus (базовое) против opus (плечо Terra)"}
SV = {"baseline / claude": "базовое / Claude", "baseline / codex": "базовое / Codex", "terra / claude": "Terra / Claude", "terra / codex": "Terra / Codex"}
sp_t = [row(["Пара (одни линзы, одна сторона заменена)", "только у первого", "только у второго", "общие"], True)] + [row([SP.get(k, k), v["aggregate"].get("a_only", 0), v["aggregate"].get("b_only", 0), v["aggregate"].get("shared", 0)]) for k, v in sp.items()]
side_t = [row(["Плечо / сторона", "Найдено", "Разобрано", "валидных", "невалидных", "неясных", "валидных major", "невалидных в финале", "severity совпала", "выборка minor"], True)]
for k, c in sv.items(): side_t.append(row([SV.get(k, k), c.get("found", 0), c.get("adjudicated", 0), c.get("verdict_valid", 0), c.get("verdict_invalid", 0), c.get("verdict_unclear", 0), c.get("valid_major", 0), c.get("invalid_kept", 0), c.get("severity_agree", 0), c.get("sampled_minor", 0)]))
t = [row(["Плечо", "Разобрано", "валидных", "невалидных", "неясных", "валидных major", "валидных в финале", "невалидных в финале"], True)]
for a in arms:
    c = pa[a]; t.append(row([AR[a], c.get("adjudicated", 0), c.get("verdict_valid", 0), c.get("verdict_invalid", 0), c.get("verdict_unclear", 0), c.get("valid_major", 0), c.get("valid_kept", 0), c.get("invalid_kept", 0)]))
g1, g2, g3 = G["gate1_unique_causes"], G["gate2_invalid"], G["gate3_control"]
def mark(ok): return "<ins>пройдены</ins>" if ok else "<del>не пройдены</del>"
gates = [row(["Ворота (объявлены 2026-10-29 до первого раунда)", "Измерено", "Правило", "Результат"], True),
         row(["1. Валидных причин только у Terra ≥ только у Sol − 3", f"{g1['terra_only']} только Terra, {g1['sol_only']} только Sol, {g1['shared']} общих", f"{g1['terra_only']} ≥ {g1['sol_only']} − 3", mark(g1["pass"])]),
         row(["2. Невалидных находок Terra ≤ 0,5 на раунд, и ≤ 1 невалидной находки Terra в финальном списке", f"{g2['terra_invalid']} невалидных в {g2['terra_rounds']} раундах ({g2['per_round']:.2f} на раунд); {g2['terra_invalid_kept']} в финальном списке", "≤ 0,5 и ≤ 1", mark(g2["pass"])]),
         row(["3. Живой контроль: Opus против Opus между плечами расходится ≤ 3 валидных причин", f"{g3['opus_baseline_only']} только базовое плечо, {g3['opus_terra_arm_only']} только плечо Terra, {g3['shared']} общих", f"|{g3['opus_baseline_only']} − {g3['opus_terra_arm_only']}| ≤ 3", "<ins>ранжировано</ins>" if g3["ranked"] else "<del>не ранжировано</del>"])]
stab = [row(["Кейс", "Плечо", "валидных причин", "во всех 3 повторах", "в 2 из 3", "в 1 из 3"], True)]
for case, arms_ in m["stability"].items():
    for a in arms:
        cs = arms_.get(a, {}); cnt = collections.Counter(cs.values()); stab.append(row([case, AR[a], len(cs), cnt.get(3, 0), cnt.get(2, 0), cnt.get(1, 0)]))
only = []
for case, d in sp["codex: sol (baseline) vs terra"]["by_case"].items():
    for side, label in (("a_only", "только Sol"), ("b_only", "только Terra")):
        for cause in d[side]:
            sev = sorted({r["severity"] for r in m["findings"] if r["case"] == case and r.get("cause") == cause and r["vendor"] == "codex"})
            only.append(row([case, label, E(cause), ", ".join(sev)]))
VD = {"valid": "валидна", "invalid": "невалидна", "unclear": "неясно"}
dis = [row(["Кейс", "Плечо", "Сторона", "Severity", "Вердикт", "Severity совпала", "Находка", "Заметка судьи"], True)]
for r in m["findings"]:
    if r.get("verdict") and r["severity"] in ("major", "critical") and (r["verdict"] != "valid" or r.get("severity_agree") is False):
        dis.append(row([r["case"], AR[r["arm"]], r["vendor"], r["severity"], VD.get(r["verdict"], r["verdict"]), "да" if r.get("severity_agree") else "нет", E(f"{r['file']}:{r['line']} {r['title']}"), E(r.get("note", ""))]))
rounds_n = sum(pa[a]["rounds"] for a in arms)
page = f"""<!doctype html><html lang="ru"><head><title>Холдаут revmux: Terra против Sol, #576</title>
<!-- kit: head -->
<!-- kit: components -->
</head><body><main lang="ru">
<hgroup><h1>Terra против Sol в revmux: предрегистрированный холдаут для #576</h1><p>{rounds_n} раундов, {datetime.date.today().isoformat()}: два плеча, пять кейсов из пяти репозиториев, три повтора; слепой разбор по запасу, объявленному до первого раунда.</p></hgroup>
<nav aria-label="Содержание"><ul><li><a href="#q">Вердикт</a></li><li><a href="#gates">Три ворот</a></li><li><a href="#setup">Схема</a></li><li><a href="#cost">Стоимость и время</a></li><li><a href="#yield">Выход поисковиков и судьба находок</a></li><li><a href="#adj">Слепой разбор</a></li><li><a href="#human">Для ручной проверки</a></li><li><a href="#limits">Ограничения</a></li><li><a href="#next">Дальше</a></li></ul></nav>
<h2 id="q">Вердикт</h2>
{V["answer"]}
<h2 id="gates">Три ворот</h2><table>{''.join(gates)}</table>
{V["gates_prose"]}
<h2 id="setup">Схема</h2>
<dl>
<dt>Плечи</dt><dd>Профили <code>bench-baseline</code> (opus 5.5 + gpt-6.1-sol) и <code>bench-terra</code> (opus 5.5 + gpt-6.1-terra) из PR #574: состав <code>dual-model</code> из десяти агентов плюс группа <code>prose</code>, одиннадцать поисковиков; синтез и верификация на opus:high в обоих. Сторона Claude одинакова в обоих плечах и служит живым контролем на одной модели.</dd>
<dt>Кейсы</dt><dd>{V["cases"]}</dd>
<dt>Порядок и бюджет</dt><dd>{V["budget"]}</dd>
<dt>Разбор</dt><dd>Слепой пакет из <code>export-blind</code> по объединённому архиву; один судья OpenCode gpt-5.6-terra на кейс по всем шести раундам кейса под непрозрачными кодами раундов и находок. Судья записал один слаг причины, одно основание и один вердикт для каждой major, каждой находки из финального списка и каждой четвёртой слитой или отброшенной minor в раунде. Ключ открыт после записи всех пяти файлов.</dd>
</dl>
<h2 id="cost">Стоимость и время</h2><table>{''.join(cost)}</table>
<p>Токены это сумма счётчиков агентов из манифестов. Счётчики Claude и Codex это разные единицы, их сравнивают только внутри вендора. Токены Codex у Terra на раунд составляют {pct(pa['terra']['codex_tokens']/pa['terra']['rounds'], pa['baseline']['codex_tokens']/pa['baseline']['rounds'])} от Sol.</p>
<h2 id="yield">Выход поисковиков и судьба находок</h2><table>{''.join(yld)}</table>
<details><summary>По кейсам и повторам</summary><table>{''.join(case_rows)}</table></details>
<h2 id="adj">Слепой разбор</h2>
<h3>Валидные причины по сторонам вендоров, с живым контролем на одной модели</h3><table>{''.join(sp_t)}</table>
<h3>Вердикты по плечам и сторонам</h3><table>{''.join(side_t)}</table>
<h3>Вердикты по плечам</h3><table>{''.join(t)}</table>
<h3>Стабильность валидных причин между повторами</h3><table>{''.join(stab)}</table>
<details><summary>Каждая причина со стороны Codex, которую нашла только одна модель</summary><table>{row(["Кейс","Сторона","Причина","Severity"],True)}{''.join(only)}</table></details>
<h2 id="human">Для ручной проверки</h2>
<p>Каждая major, которую судья не назвал валидной, или с чьей severity он не согласился: {len(dis)-1} строк.</p>
<table>{''.join(dis)}</table>
<h2 id="limits">Ограничения</h2>
{V["limits"]}
<h2 id="next">Дальше</h2>
{V["next"]}
</main>
<!-- kit: scripts -->
</body></html>"""
open(f"{B}/report-draft-ru.html", "w").write(page); print("draft written", len(page))
