"""Build the #577 scope-instruction report draft (bare semantic HTML with render-kit markers) from metrics.json and verdict.json."""
import json, sys, html, datetime
R = sys.argv[1]; m = json.load(open(f"{R}/metrics.json")); V = json.load(open(f"{R}/verdict.json"))
E = html.escape
def row(cells, th=False):
    t = "th" if th else "td"; return "<tr>" + "".join(f"<{t}>{c}</{t}>" for c in cells) + "</tr>"
arms = ["baseline", "scope"]
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
page = f"""<!doctype html><html lang="en"><head><title>Revmux scope instruction for test doubles: #577 measurement</title>
<!-- kit: head -->
<!-- kit: components -->
</head><body><main lang="en">
<hgroup><h1>Does a scope line that pairs each test double with what it stands for make revmux see weak test evidence?</h1>
<p>Issue #577, candidate 1 of its list · the managed <code>lean</code> profile as baseline · {datetime.date.today().isoformat()} · 18 new candidate rounds against the 18 baseline rounds of the #249 measurement, label adjudication by three blind-to-arm agents under opaque round ids</p></hgroup>
<nav aria-label="Contents"><ul><li><a href="#q">Answer</a></li><li><a href="#setup">Setup</a></li><li><a href="#hits">Hits and false positives</a></li><li><a href="#cost">Cost</a></li><li><a href="#notes">Per-round verdicts</a></li><li><a href="#limits">Limitations</a></li><li><a href="#next">Next</a></li></ul></nav>
<h2 id="q">Answer</h2>
{V["answer"]}
<h2 id="setup">Setup</h2>
<dl>
<dt>Baseline</dt><dd>The managed <code>lean</code> profile unchanged: five finders (three Claude opus 5.5 groups, two Codex gpt-6.1-sol groups), synthesis and verification on opus:high. The <code>tests</code> lens is revmux's embedded text.</dd>
<dt>Candidate</dt><dd>The same profile, no prompt text changed. Each round's <code>scope.md</code> gains one section, <em>Read in full, side by side</em>, that names every test double the diff touches or drives and what it stands for: the Pi <code>ui</code> fake and the command fakes against the extension's call sites (pair 2); the generated <code>herdr</code> and <code>git</code> stand-ins against the installed CLI and their callers (pair 3); the generated <code>herdr</code> stand-in and model stub against the installed CLI and <code>herdr-task-sync</code> (pair 4). The wording names files and commands only; it does not say what to look for.</dd>
<dt>Cases</dt><dd>Three labelled pairs from the #249 seed ranges, each a <em>bad</em> change (the commit that introduced the weak test) and its <em>repaired</em> change (the later fix). Pair 1 of the corpus, the 21k-line Bats to bashunit migration, was left out as too large for a lens measurement. The candidate ran each of the six changes three times (18 rounds). The baseline arm is the 18 <code>lean</code> rounds of the #249 measurement of 2026-10-28: same frozen cases, same profile, same revmux build and scratch config, so they were reused instead of paid for again; the two arms are two days apart.</dd>
<dt>Labels</dt><dd><dl>{''.join(labels)}</dl></dd>
<dt>Adjudication</dt><dd>One OpenCode gpt-5.6-terra agent per pair read every round's finder candidates and final list, with the labelled defect and the frozen code, and recorded for each round whether a candidate names the labelled weakness (finder hit), whether a final-list finding does (final hit), and on repaired rounds which final findings claim a defect the repaired code does not have (false positive). Both arms' rounds of a pair were shuffled under opaque round ids before the adjudicator saw them, the method the #249 measurement settled on after its per-arm pass disagreed with itself.</dd>
</dl>
<h2 id="hits">Hits and false positives</h2>
<table>{''.join(hits)}</table>
{V["hits_prose"]}
<h2 id="cost">Cost</h2>
<table>{''.join(cost)}</table>
<h2 id="notes">Per-round verdicts</h2>
<details><summary>36 rows, one per round (18 baseline from #249, 18 candidate), with the adjudicator's sentence</summary><table>{row(["Arm","Pair","Stage","Rep","Result","Adjudicator's note"], True)}{''.join(notes)}</table></details>
<h2 id="limits">Limitations</h2>
{V["limits"]}
<h2 id="next">Next</h2>
{V["next"]}
</main>
<!-- kit: scripts -->
</body></html>"""
open(f"{R}/draft.html", "w").write(page); print("draft written", len(page))
