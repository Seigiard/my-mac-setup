"""Build the #249 report draft (bare semantic HTML with render-kit markers) from metrics.json and verdict.json."""
import json, sys, html, datetime
R = sys.argv[1]; m = json.load(open(f"{R}/metrics.json")); V = json.load(open(f"{R}/verdict.json"))
E = html.escape
def row(cells, th=False):
    t = "th" if th else "td"; return "<tr>" + "".join(f"<{t}>{c}</{t}>" for c in cells) + "</tr>"
arms = ["baseline", "candidate"]
hits = [row(["Pair", "Category", "Arm", "bad rounds", "finder hit", "final-list hit", "lost in pipeline", "repaired rounds", "false positives"], True)]
for pair, v in m["pairs"].items():
    for a in arms:
        s = v[a]; hits.append(row([pair if a == "baseline" else "", v["category"] if a == "baseline" else "", a, s["bad_rounds"], s["found_hits"], s["final_hits"], s["lost_in_pipeline"], s["repaired_rounds"], s["false_positives"]]))
tot = {a: {k: sum(v[a][k] for v in m["pairs"].values()) for k in ("bad_rounds", "found_hits", "final_hits", "repaired_rounds", "false_positives")} for a in arms}
for a in arms:
    t = tot[a]; hits.append(row(["<strong>all pairs</strong>" if a == "baseline" else "", "", f"<strong>{a}</strong>", t["bad_rounds"], f"<strong>{t['found_hits']}</strong>", f"<strong>{t['final_hits']}</strong>", "", t["repaired_rounds"], f"<strong>{t['false_positives']}</strong>"]))
cost = [row(["Arm", "Rounds", "Degraded", "Tokens / round", "Claude / round", "Codex / round", "docs+tests agent / round", "Minutes / round", "Final findings / round"], True)]
for a in arms:
    c = m["cost"][a]["total"]; n = c["rounds"]
    cost.append(row([a, n, c["degraded"], f"{c['tokens']/n/1e6:.1f}M", f"{c['claude']/n/1e6:.1f}M", f"{c['codex']/n/1e6:.2f}M", f"{c['docs_tests']/n/1e6:.2f}M", f"{c['ms']/n/60000:.1f}", f"{c['final_findings']/n:.1f}"]))
labels = []
for pair, v in m["pairs"].items():
    labels.append(f"<dt>{pair} · {E(v['category'])}</dt><dd>{E(v['defect'])} <small>{E(v['basis'])}</small></dd>")
notes = []
for a in arms:
    for r in m["rows"][a]:
        tag = "<ins>hit</ins>" if r.get("final_hit") else ("<mark>finder only</mark>" if r.get("found_hit") else ("<del>false positive</del>" if r.get("false_positive") else "<small>none</small>"))
        notes.append(row([a, r["pair"], r["stage"], r["task"].split("#")[1], tag, E(r.get("note", ""))]))
page = f"""<!doctype html><html lang="en"><head><title>Revmux test-evidence lens: #249 measurement</title>
<!-- kit: head -->
<!-- kit: components -->
</head><body><main lang="en">
<hgroup><h1>Does one block in the <code>tests</code> lens make revmux see weak test evidence?</h1>
<p>Issue #249 · the managed <code>lean</code> profile as baseline · {datetime.date.today().isoformat()} · 36 rounds, label adjudication by three blind-to-arm agents</p></hgroup>
<nav aria-label="Contents"><ul><li><a href="#q">Answer</a></li><li><a href="#setup">Setup</a></li><li><a href="#hits">Hits and false positives</a></li><li><a href="#cost">Cost</a></li><li><a href="#notes">Per-round verdicts</a></li><li><a href="#limits">Limitations</a></li><li><a href="#next">Next</a></li></ul></nav>
<h2 id="q">Answer</h2>
{V["answer"]}
<h2 id="setup">Setup</h2>
<dl>
<dt>Baseline</dt><dd>The managed <code>lean</code> profile unchanged: five finders (three Claude opus 5.5 groups, two Codex gpt-6.1-sol groups), synthesis and verification on opus:high. The <code>tests</code> lens is revmux's embedded text.</dd>
<dt>Candidate</dt><dd>The same profile with one addition to the <code>tests</code> lens, twelve lines: ask where a test's expected value comes from, and name two sources that make a test green by construction: a fake that reimplements a production rule, and an expected value from the same helper, allocator, table or path as the value under test, including a historical constant copied from one earlier run. Nothing else in the prompt changed; the diff of the composed finder prompt is exactly that block.</dd>
<dt>Cases</dt><dd>Three labelled pairs from the #249 seed ranges, each a <em>bad</em> change (the commit that introduced the weak test) and its <em>repaired</em> change (the later fix). Pair 1 of the corpus, the 21k-line Bats to bashunit migration, was left out as too large for a lens measurement. Each of the six changes ran three times per arm: 18 rounds per arm, 36 in all, none degraded.</dd>
<dt>Labels</dt><dd><dl>{''.join(labels)}</dl></dd>
<dt>Adjudication</dt><dd>One OpenCode gpt-5.6-terra agent per pair read every round's finder candidates and final list, with the labelled defect and the frozen code, and recorded for each round whether a candidate names the labelled weakness (finder hit), whether a final-list finding does (final hit), and on repaired rounds which final findings claim a defect the repaired code does not have (false positive). The adjudicator saw task names, not arm names; both arms' task names carry an arm token, so the blinding is weaker than the #408 packet's and is listed under limitations.</dd>
</dl>
<h2 id="hits">Hits and false positives</h2>
<table>{''.join(hits)}</table>
{V["hits_prose"]}
<h2 id="cost">Cost</h2>
<table>{''.join(cost)}</table>
<h2 id="notes">Per-round verdicts</h2>
<details><summary>36 rows, one per round, with the adjudicator's sentence</summary><table>{row(["Arm","Pair","Stage","Rep","Result","Adjudicator's note"], True)}{''.join(notes)}</table></details>
<h2 id="limits">Limitations</h2>
{V["limits"]}
<h2 id="next">Next</h2>
{V["next"]}
</main>
<!-- kit: scripts -->
</body></html>"""
open(f"{R}/draft.html", "w").write(page); print("draft written", len(page))
