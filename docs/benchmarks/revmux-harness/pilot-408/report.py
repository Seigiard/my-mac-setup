"""Build the #408 pilot report draft (bare semantic HTML with render-kit markers) from metrics.json."""
import json, sys, html, collections, datetime
B = sys.argv[1]; m = json.load(open(f"{B}/metrics.json"))
pa = m["per_arm"]; arms = ["baseline", "sonnet", "terra"]
E = html.escape
def pct(a, b): return f"{100*a/b:.0f}%" if b else "–"
def row(cells, th=False):
    t = "th" if th else "td"; return "<tr>" + "".join(f"<{t}>{c}</{t}>" for c in cells) + "</tr>"
adjudicated = any("verdict" in r for r in m["findings"])
# cost table
cost = [row(["Arm", "Finder models", "Rounds", "Tokens / round", "Claude tokens / round", "Codex tokens / round", "Minutes / round"], True)]
models = {"baseline": "opus 5.5 + gpt-6.1-sol", "sonnet": "sonnet 5.5 + gpt-6.1-sol", "terra": "opus 5.5 + gpt-6.1-terra"}
for a in arms:
    c = pa[a]; n = c["rounds"]
    cost.append(row([a, models[a], n, f"{c['tokens']/n/1e6:.1f}M", f"{c['claude_tokens']/n/1e6:.1f}M", f"{c['codex_tokens']/n/1e6:.2f}M", f"{c['duration_ms']/n/60000:.1f}"]))
# yield table
yld = [row(["Arm", "Found", "major", "Claude side", "Codex side", "Kept to final", "Dropped", "Merged", "pre-existing / immaterial / question"], True)]
for a in arms:
    c = pa[a]
    yld.append(row([a, c["found"], c.get("found_major", 0), c.get("found_claude", 0), c.get("found_codex", 0), c.get("fate_kept", 0), c.get("fate_dropped", 0), c.get("fate_merged", 0), f"{c.get('fate_pre_existing',0)} / {c.get('fate_immaterial',0)} / {c.get('fate_open_question',0)}"]))
# per case per rep kept counts
case_rows = [row(["Case", "Arm", "rep 1 found→kept", "rep 2 found→kept", "rep 3 found→kept"], True)]
fk = collections.defaultdict(lambda: [0, 0])
for r in m["findings"]:
    k = (r["case"], r["arm"], r["rep"]); fk[k][0] += 1; fk[k][1] += r["fate"] == "kept"
for case in sorted({r["case"] for r in m["findings"]}):
    for a in arms:
        case_rows.append(row([case, a] + [f"{fk[(case,a,i)][0]}→{fk[(case,a,i)][1]}" for i in (1, 2, 3)]))
# adjudication
adj_html = "<p>Adjudication pending.</p>"
sv = json.load(open(f"{B}/side_verdicts.json")); sp = m.get("side_pairs", {})
def sp_row(label):
    g = sp[label]["aggregate"]; return row([label, g.get("a_only", 0), g.get("b_only", 0), g.get("shared", 0)])
if adjudicated:
    t = [row(["Arm", "Adjudicated", "valid", "invalid", "unclear", "valid majors", "valid in final list", "invalid in final list"], True)]
    for a in arms:
        c = pa[a]
        t.append(row([a, c.get("adjudicated", 0), c.get("verdict_valid", 0), c.get("verdict_invalid", 0), c.get("verdict_unclear", 0), c.get("valid_major", 0), c.get("valid_kept", 0), c.get("invalid_kept", 0)]))
    pairs = [row(["Candidate vs baseline", "baseline-only causes", "candidate-only causes", "shared causes"], True)]
    for cand in ("sonnet", "terra"):
        g = m["pairs"][cand]["aggregate"]
        pairs.append(row([cand, g.get("baseline_only", 0), g.get("candidate_only", 0), g.get("shared", 0)]))
    stab = [row(["Case", "Arm", "valid causes", "seen in 3 of 3 reps", "in 2 of 3", "in 1 of 3"], True)]
    for case, arms_ in m["stability"].items():
        for a in arms:
            cs = arms_.get(a, {}); cnt = collections.Counter(cs.values())
            stab.append(row([case, a, len(cs), cnt.get(3, 0), cnt.get(2, 0), cnt.get(1, 0)]))
    only = []
    for cand in ("sonnet", "terra"):
        for case, d in m["pairs"][cand]["by_case"].items():
            for side in ("baseline_only", "candidate_only"):
                for cause in d[side]:
                    sev = sorted({r["severity"] for r in m["findings"] if r["case"] == case and r.get("cause") == cause})
                    only.append(row([cand, case, side.replace("_", " "), E(cause), ", ".join(sev)]))
    side_t = [row(["Arm / side", "Adjudicated", "valid", "invalid", "unclear", "valid majors", "valid in final list"], True)]
    for k, c in sv.items(): side_t.append(row([k, c["adj"], c["valid"], c["invalid"], c["unclear"], c["valid_major"], c["valid_kept"]]))
    sp_t = [row(["Pair (same lenses, one side swapped)", "first only", "second only", "shared"], True)] + [sp_row(k) for k in sp]
    adj_html = f"""<h3>Valid causes per vendor side: candidate against baseline, with same-model controls</h3><p>Each row compares the set of adjudicated-valid causes one vendor side raised across all nine rounds of two arms. The two control rows compare the same model with itself across arms, so they show the repetition noise a real difference must exceed.</p><table>{''.join(sp_t)}</table>
<h3>Verdicts per arm and vendor side</h3><table>{''.join(side_t)}</table>
<h3>Verdicts per arm</h3><table>{''.join(t)}</table>
<h3>Cause groups, candidate against baseline (valid causes, all three repetitions pooled)</h3><table>{''.join(pairs)}</table>
<h3>Stability of valid causes across repetitions</h3><table>{''.join(stab)}</table>
<details><summary>Every cause found by one side only</summary><table>{row(["Pair","Case","Side","Cause","Severity"],True)}{''.join(only)}</table></details>"""
rounds_n = sum(pa[a]["rounds"] for a in arms)
page = f"""<!doctype html><html lang="en"><head><title>Revmux model pilot, #408</title>
<!-- kit: head -->
<!-- kit: components -->
</head><body><main lang="en">
<hgroup><h1>Revmux model pilot for #408</h1><p>{rounds_n} rounds on {datetime.date.today().isoformat()}: three arms, three cases, three repetitions. Pilot, not holdout: it sizes the holdout and proves the chain, it does not decide the hypotheses.</p></hgroup>
<nav aria-label="Contents"><ul><li><a href="#q">Questions and answers</a></li><li><a href="#setup">Setup</a></li><li><a href="#cost">Cost and latency</a></li><li><a href="#yield">Finder yield and pipeline fates</a></li><li><a href="#adj">Blind adjudication</a></li><li><a href="#limits">Limitations</a></li><li><a href="#next">What the holdout needs</a></li></ul></nav>
<h2 id="q">Questions and answers</h2>
<dl>
<dt>Does the chain work end to end?</dt><dd>Yes. Harness → 27 archived rounds, none degraded or unreadable → blind packet → three adjudicators who never saw the key → this report. The key was opened only after every adjudication file was written.</dd>
<dt>Sonnet instead of Opus</dt><dd><del>Not supported by this pilot.</del> With the same lenses, the Opus side raised 12 adjudicated-valid causes that the Sonnet side never raised, against 1 the other way, with 7 shared; the same-model control (Opus against Opus across arms) is 5 against 4 with 14 shared, so the gap is well outside repetition noise. Sonnet raised no valid major at all (0 against 17 for Opus) and cost {pct(pa['sonnet']['claude_tokens'], pa['baseline']['claude_tokens'])} of the Claude tokens. The holdout can still run, but the pilot gives no reason to expect a different answer.</dd>
<dt>Terra instead of Sol</dt><dd><mark>Open.</mark> The Codex side raised 9 valid causes only on Sol and 10 only on Terra, with 5 shared; the Sol-against-Sol control is 6 against 4 with 8 shared, so the Codex side is noisy on its own and Terra is at least as productive. Terra raised more majors (27 valid majors against 9) and more invalid findings (4 against 0), at {pct(pa['terra']['codex_tokens'], pa['baseline']['codex_tokens'])} of Sol's Codex token count. This is the pair the holdout must settle, with a declared margin.</dd>
<dt>How noisy is one round?</dt><dd>The Claude side was identical in the baseline and Terra arms: over nine rounds each it raised {pa['baseline'].get('found_claude',0)} and {pa['terra'].get('found_claude',0)} findings and 14 shared valid causes with 5 and 4 unique. In the baseline arm, only 11 of its 28 valid causes appeared in all three repetitions of their case. A single round ranks nothing; three repetitions per case is the minimum the holdout should keep.</dd>
<dt>Does the pipeline keep what the adjudicator calls valid?</dt><dd>Across all 27 rounds, {sum(pa[a].get('invalid_kept',0) for a in arms)} adjudicated-invalid finding reached a final list; the rest of the invalid and unclear findings were merged, dropped or reclassified before the final list. Synthesis and verification on Opus did their job in every arm.</dd>
</dl>
<h2 id="setup">Setup</h2>
<dl>
<dt>Arms</dt><dd>Profiles <code>bench-baseline</code>, <code>bench-sonnet</code>, <code>bench-terra</code>: the ten-agent <code>dual-model</code> roster plus one <code>prose</code> lens group on the Claude side, eleven finders. Synthesis and verification on opus:high in every arm. Baseline = opus 5.5 + gpt-6.1-sol; Sonnet arm swaps every Claude agent to sonnet 5.5; Terra arm swaps every Codex agent to gpt-6.1-terra. The <code>gpt-6-terra</code> named in the issue is no longer in the Codex catalog.</dd>
<dt>Preflight</dt><dd>Real authenticated requests on this machine: Claude Code 2.1.308 answered on opus and sonnet; Codex CLI 0.164.0 answered on gpt-6.1-sol and gpt-6.1-terra. Every manifest records the actual model equal to the requested one; no fallback occurred.</dd>
<dt>Cases</dt><dd><code>issue-509</code> (my-mac-setup, shell hooks + bashunit tests, 3 files; the checkout carries <code>.revmux/profile.md</code>), <code>prd-3488</code> (membranehq/platform, SDK + plugin CLI + tests + docs, 17 files; no profile), <code>r249-2</code> (my-mac-setup, TypeScript extension + tests + two issue documents, 4 files; no profile at that commit). Frozen detached checkouts at the corpus SHAs; identical scope and goal text per case across arms.</dd>
<dt>Order and budget</dt><dd>Case-major, one repetition per pass, three passes; each round started only while the Claude weekly quota was under the maintainer's 35% cap. The quota went from 15% to 19% over the 27 rounds, this session included.</dd>
<dt>Adjudication</dt><dd>One blind adjudicator per case (OpenCode on gpt-5.6-terra, effort high) read the frozen code and recorded one basis and one cause slug per finding for every major finding and every final-list finding; minors that synthesis merged or dropped were not adjudicated. Arms were revealed only after all three files existed.</dd>
</dl>
<h2 id="cost">Cost and latency</h2><table>{''.join(cost)}</table>
<p>Tokens are the manifests' per-agent counters summed; Claude and Codex counters are not the same unit and are compared only within a vendor. Minutes are wall clock per round including synthesis and verification, agents capped at six in parallel.</p>
<h2 id="yield">Finder yield and pipeline fates</h2><table>{''.join(yld)}</table>
<p>Found counts every finding the eleven finders raised; kept are those on the final list. Merged means synthesis folded it into another finding; dropped means an explicit drop event.</p>
<details><summary>Per case and repetition</summary><table>{''.join(case_rows)}</table></details>
<h2 id="adj">Blind adjudication</h2>{adj_html}
<h2 id="limits">Limitations</h2>
<ul>
<li>Three cases from two repositories; no prose-only diff, so the prose group was measured on code diffs with incidental documents.</li>
<li>The adjudicator is itself a model (gpt-5.6-terra); its verdicts are a blind second reading of the frozen code, not a human ground truth. Prior human verdicts exist only for <code>r249-2</code>.</li>
<li>Merged and dropped minors were not adjudicated, so a lens that raised many near-duplicates is not penalised or credited for them.</li>
<li>Codex token counters in the manifests do not include reasoning tokens the same way Claude's do; cost per vendor is read within the vendor only.</li>
<li>Synthesis and verification stayed on opus in every arm, so an arm's final list also reflects how opus treats that arm's candidates.</li>
</ul>
<h2 id="next">What the holdout needs</h2>
<ul>
<li>Non-inferiority margin set from the observed repetition spread above, per vendor side.</li>
<li>Cases from all five repositories of the corpus, with at least one agent-document diff and the <code>r249</code> labelled cases kept out of tuning.</li>
<li>Adjudication of a declared sample of merged and dropped minors, and a human pass over every major disagreement.</li>
</ul>
</main>
<!-- kit: scripts -->
</body></html>"""
open(f"{B}/report-draft.html", "w").write(page); print("draft written", len(page))
