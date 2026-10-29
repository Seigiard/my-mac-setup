"""Build the #576 holdout report draft (bare semantic HTML with render-kit markers) from metrics.json and verdict.json."""
import json, sys, html, collections, datetime
B = sys.argv[1]; m = json.load(open(f"{B}/metrics.json")); V = json.load(open(f"{B}/verdict.json"))
pa = m["per_arm"]; arms = ["baseline", "terra"]; G = m["gates"]
E = html.escape
def pct(a, b): return f"{100*a/b:.0f}%" if b else "–"
def row(cells, th=False):
    t = "th" if th else "td"; return "<tr>" + "".join(f"<{t}>{c}</{t}>" for c in cells) + "</tr>"
models = {"baseline": "opus 5.5 + gpt-6.1-sol", "terra": "opus 5.5 + gpt-6.1-terra"}
cost = [row(["Arm", "Finder models", "Rounds", "Degraded", "Tokens / round", "Claude tokens / round", "Codex tokens / round", "Minutes / round"], True)]
for a in arms:
    c = pa[a]; n = c["rounds"]
    cost.append(row([a, models[a], n, c.get("degraded", 0), f"{c['tokens']/n/1e6:.1f}M", f"{c['claude_tokens']/n/1e6:.1f}M", f"{c['codex_tokens']/n/1e6:.2f}M", f"{c['duration_ms']/n/60000:.1f}"]))
yld = [row(["Arm", "Found", "major", "Claude side", "Codex side", "Kept to final", "Dropped", "Merged", "pre-existing / immaterial / question"], True)]
for a in arms:
    c = pa[a]
    yld.append(row([a, c["found"], c.get("found_major", 0), c.get("found_claude", 0), c.get("found_codex", 0), c.get("fate_kept", 0), c.get("fate_dropped", 0), c.get("fate_merged", 0), f"{c.get('fate_pre_existing',0)} / {c.get('fate_immaterial',0)} / {c.get('fate_open_question',0)}"]))
case_rows = [row(["Case", "Arm", "rep 1 found→kept", "rep 2 found→kept", "rep 3 found→kept"], True)]
fk = collections.defaultdict(lambda: [0, 0])
for r in m["findings"]:
    k = (r["case"], r["arm"], r["rep"]); fk[k][0] += 1; fk[k][1] += r["fate"] == "kept"
for case in sorted({r["case"] for r in m["findings"]}):
    for a in arms:
        case_rows.append(row([case, a] + [f"{fk[(case,a,i)][0]}→{fk[(case,a,i)][1]}" for i in (1, 2, 3)]))
sp = m["side_pairs"]; sv = m["side_verdicts"]
sp_t = [row(["Pair (same lenses, one side swapped)", "first only", "second only", "shared"], True)] + [row([k, v["aggregate"].get("a_only", 0), v["aggregate"].get("b_only", 0), v["aggregate"].get("shared", 0)]) for k, v in sp.items()]
side_t = [row(["Arm / side", "Found", "Adjudicated", "valid", "invalid", "unclear", "valid majors", "invalid on a final list", "severity agreed", "sampled minors"], True)]
for k, c in sv.items(): side_t.append(row([k, c.get("found", 0), c.get("adjudicated", 0), c.get("verdict_valid", 0), c.get("verdict_invalid", 0), c.get("verdict_unclear", 0), c.get("valid_major", 0), c.get("invalid_kept", 0), c.get("severity_agree", 0), c.get("sampled_minor", 0)]))
t = [row(["Arm", "Adjudicated", "valid", "invalid", "unclear", "valid majors", "valid in final list", "invalid in final list"], True)]
for a in arms:
    c = pa[a]; t.append(row([a, c.get("adjudicated", 0), c.get("verdict_valid", 0), c.get("verdict_invalid", 0), c.get("verdict_unclear", 0), c.get("valid_major", 0), c.get("valid_kept", 0), c.get("invalid_kept", 0)]))
g1, g2, g3 = G["gate1_unique_causes"], G["gate2_invalid"], G["gate3_control"]
def mark(ok): return "<ins>pass</ins>" if ok else "<del>fail</del>"
gates = [row(["Gate (declared 2026-10-29, before the first round)", "Measured", "Rule", "Result"], True),
         row(["1. Terra-only valid causes ≥ Sol-only valid causes − 3", f"{g1['terra_only']} Terra-only, {g1['sol_only']} Sol-only, {g1['shared']} shared", f"{g1['terra_only']} ≥ {g1['sol_only']} − 3", mark(g1["pass"])]),
         row(["2. Terra invalid findings ≤ 0.5 per round, and ≤ 1 invalid Terra finding on a final list", f"{g2['terra_invalid']} invalid in {g2['terra_rounds']} rounds ({g2['per_round']:.2f} per round); {g2['terra_invalid_kept']} on a final list", "≤ 0.5 and ≤ 1", mark(g2["pass"])]),
         row(["3. Live control: Opus against Opus across arms differs by ≤ 3 unique valid causes", f"{g3['opus_baseline_only']} baseline-arm only, {g3['opus_terra_arm_only']} Terra-arm only, {g3['shared']} shared", f"|{g3['opus_baseline_only']} − {g3['opus_terra_arm_only']}| ≤ 3", "<ins>ranked</ins>" if g3["ranked"] else "<del>unranked</del>"])]
stab = [row(["Case", "Arm", "valid causes", "seen in 3 of 3 reps", "in 2 of 3", "in 1 of 3"], True)]
for case, arms_ in m["stability"].items():
    for a in arms:
        cs = arms_.get(a, {}); cnt = collections.Counter(cs.values()); stab.append(row([case, a, len(cs), cnt.get(3, 0), cnt.get(2, 0), cnt.get(1, 0)]))
only = []
for case, d in sp["codex: sol (baseline) vs terra"]["by_case"].items():
    for side, label in (("a_only", "Sol only"), ("b_only", "Terra only")):
        for cause in d[side]:
            sev = sorted({r["severity"] for r in m["findings"] if r["case"] == case and r.get("cause") == cause and r["vendor"] == "codex"})
            only.append(row([case, label, E(cause), ", ".join(sev)]))
dis = [row(["Case", "Arm", "Side", "Severity", "Verdict", "Severity agreed", "Finding", "Adjudicator's note"], True)]
for r in m["findings"]:
    if r.get("verdict") and r["severity"] in ("major", "critical") and (r["verdict"] != "valid" or r.get("severity_agree") is False):
        dis.append(row([r["case"], r["arm"], r["vendor"], r["severity"], r["verdict"], r.get("severity_agree"), E(f"{r['file']}:{r['line']} {r['title']}"), E(r.get("note", ""))]))
rounds_n = sum(pa[a]["rounds"] for a in arms)
page = f"""<!doctype html><html lang="en"><head><title>Revmux holdout: Terra against Sol, #576</title>
<!-- kit: head -->
<!-- kit: components -->
</head><body><main lang="en">
<hgroup><h1>Terra against Sol in revmux: the pre-registered holdout for #576</h1><p>{rounds_n} rounds, {datetime.date.today().isoformat()}: two arms, five cases from five repositories, three repetitions; blind adjudication under the margin declared before the first round.</p></hgroup>
<nav aria-label="Contents"><ul><li><a href="#q">Verdict</a></li><li><a href="#gates">The three gates</a></li><li><a href="#setup">Setup</a></li><li><a href="#cost">Cost and latency</a></li><li><a href="#yield">Finder yield and pipeline fates</a></li><li><a href="#adj">Blind adjudication</a></li><li><a href="#human">For the human pass</a></li><li><a href="#limits">Limitations</a></li><li><a href="#next">Next</a></li></ul></nav>
<h2 id="q">Verdict</h2>
{V["answer"]}
<h2 id="gates">The three gates</h2><table>{''.join(gates)}</table>
{V["gates_prose"]}
<h2 id="setup">Setup</h2>
<dl>
<dt>Arms</dt><dd>Profiles <code>bench-baseline</code> (opus 5.5 + gpt-6.1-sol) and <code>bench-terra</code> (opus 5.5 + gpt-6.1-terra) from PR #574: the ten-agent <code>dual-model</code> roster plus the <code>prose</code> group, eleven finders; synthesis and verification on opus:high in both. The Claude side is the same in both arms and serves as the live same-model control.</dd>
<dt>Cases</dt><dd>{V["cases"]}</dd>
<dt>Order and budget</dt><dd>{V["budget"]}</dd>
<dt>Adjudication</dt><dd>Blind packet from <code>export-blind</code> over the merged archive; one OpenCode gpt-5.6-terra adjudicator per case over all six rounds of the case under opaque round and finding codes, recording one cause slug, one basis and one verdict per finding for every major, every final-list finding and every fourth merged or dropped minor per round. The key was opened after all five files were written.</dd>
</dl>
<h2 id="cost">Cost and latency</h2><table>{''.join(cost)}</table>
<p>Tokens are the manifests' per-agent counters summed; Claude and Codex counters are not the same unit and are compared only within a vendor. Terra's Codex tokens per round are {pct(pa['terra']['codex_tokens']/pa['terra']['rounds'], pa['baseline']['codex_tokens']/pa['baseline']['rounds'])} of Sol's.</p>
<h2 id="yield">Finder yield and pipeline fates</h2><table>{''.join(yld)}</table>
<details><summary>Per case and repetition</summary><table>{''.join(case_rows)}</table></details>
<h2 id="adj">Blind adjudication</h2>
<h3>Valid causes per vendor side, with the live same-model control</h3><table>{''.join(sp_t)}</table>
<h3>Verdicts per arm and vendor side</h3><table>{''.join(side_t)}</table>
<h3>Verdicts per arm</h3><table>{''.join(t)}</table>
<h3>Stability of valid causes across repetitions</h3><table>{''.join(stab)}</table>
<details><summary>Every Codex-side cause found by one model only</summary><table>{row(["Case","Side","Cause","Severity"],True)}{''.join(only)}</table></details>
<h2 id="human">For the human pass</h2>
<p>Every major finding the adjudicator did not call valid, or whose severity it disagreed with: {len(dis)-1} rows.</p>
<table>{''.join(dis)}</table>
<h2 id="limits">Limitations</h2>
{V["limits"]}
<h2 id="next">Next</h2>
{V["next"]}
</main>
<!-- kit: scripts -->
</body></html>"""
open(f"{B}/report-draft.html", "w").write(page); print("draft written", len(page))
