#!/usr/bin/env python3
"""The blind human leg: sample pairs, serve them without labels, record verdicts.

The mechanical leg asks whether the rules were obeyed. This leg asks whether the
answer got easier to use, which is the question the counters cannot reach.

Blinding is the whole value of the leg, so provenance lives in exactly one
place. `prepare` draws a presentation order per pair and returns two things: the
payloads the handler serves, which name no arm, and the key, which names both.
The handler receives only the payloads and never reads the key file. The key is
joined back at report time.

The rater sees two fixed binary questions and no numeric scale. With eight pairs
a scale clusters mid-range and drifts between sessions, and a forced binary with
a tie is what this sample size supports.
"""

import hashlib
import math
import http.server
import json
import os
import random
import re
import socketserver
import webbrowser
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

HARNESS_VERSION = 1
DEFAULT_BATCH = 8
PAIR_ARMS = ("baseline", "candidate")

RESPONSE_NAME = re.compile(r"^(?P<language>[a-z]+)__(?P<prompt_id>.+)__(?P<arm>[a-z]+)__r(?P<repeat>\d+)$")

# Fixed wording. The hash travels with every verdict, so a later session that
# reworded a question is detectable rather than silently incomparable.
QUESTIONS = (
    {"key": "faster",
     "text": "Which response gets you to the next action faster, with less re-reading?",
     "options": [("A", "A"), ("B", "B"), ("same", "no difference")]},
    {"key": "missing",
     "text": "Does either response leave out something important that the other has?",
     "options": [("A", "A"), ("B", "B"), ("neither", "neither")]},
)

def two_sided_probability(total, extreme):
    """P(a split at least this lopsided) under a fair coin."""
    if total == 0:
        return 1.0
    tail = sum(math.comb(total, i) for i in range(extreme, total + 1))
    return min(1.0, tail * 2 / 2 ** total)


def resolving_power(total):
    """State what this many side-naming verdicts can and cannot separate from chance.

    A tally is worth nothing without this line. The threshold is computed rather
    than quoted, because the batch size changes and a fixed sentence would keep
    claiming the power of a batch that was not rated.
    """
    if total == 0:
        return ("No verdict named a side for this question, so nothing here "
                "separates from chance.")

    threshold = None
    for extreme in range(total // 2 + 1, total + 1):
        if two_sided_probability(total, extreme) <= 0.05:
            threshold = extreme
            break
    if threshold is None:
        return (f"{total} verdict(s) named a side. At this sample size no split "
                "reaches p = 0.05, so read the tally as no signal whatever it says.")

    line = (f"{total} verdict(s) named a side. A split reaches p = 0.05 at "
            f"{threshold}-{total - threshold} "
            f"(p = {two_sided_probability(total, threshold):.3f}). "
            "A more even split is no signal.")
    if threshold - 1 > total / 2:
        borderline = two_sided_probability(total, threshold - 1)
        if borderline <= 0.10:
            line += (f" The next split down, {threshold - 1}-{total - threshold + 1}, "
                     f"sits at p = {borderline:.2f} and is suggestive rather than "
                     "separated.")
    return line


def questions_hash():
    joined = "\n".join(question["text"] for question in QUESTIONS)
    return hashlib.sha256(joined.encode("utf-8")).hexdigest()


def pair_id(language, prompt_id, repeat):
    return f"{language}::{prompt_id}::r{repeat}"


def available_pairs(run_dir):
    """Every prompt and repeat where both compared arms produced a response."""
    responses = Path(run_dir) / "responses"
    found = {}
    for path in sorted(responses.glob("*.txt")):
        match = RESPONSE_NAME.match(path.stem)
        if not match:
            continue
        if not path.read_text().strip():
            continue
        found[(match.group("language"), match.group("prompt_id"),
               int(match.group("repeat")), match.group("arm"))] = path

    pairs = []
    seen = sorted({(language, prompt, repeat)
                   for language, prompt, repeat, _ in found})
    for language, prompt, repeat in seen:
        if all((language, prompt, repeat, arm) in found for arm in PAIR_ARMS):
            pairs.append({"language": language, "prompt_id": prompt, "repeat": repeat})
    return pairs


def stratified_sample(pairs, batch, seed):
    """Take `batch` pairs spread across languages, deterministically.

    Round-robin over languages so a batch never measures one language only, with
    each language's own order drawn from the rating seed.
    """
    if batch <= 0 or batch >= len(pairs):
        return list(pairs)

    by_language = {}
    for pair in pairs:
        by_language.setdefault(pair["language"], []).append(pair)

    rng = random.Random(seed)
    for language in by_language:
        rng.shuffle(by_language[language])

    chosen = []
    languages = sorted(by_language)
    index = 0
    while len(chosen) < batch:
        progressed = False
        for language in languages:
            if index < len(by_language[language]) and len(chosen) < batch:
                chosen.append(by_language[language][index])
                progressed = True
        if not progressed:
            break
        index += 1
    return chosen


def prepare(run_dir, seed, batch=DEFAULT_BATCH):
    """Return (payloads, key).

    The payload is what the rater sees. The key is what resolves it to an arm.
    They are built here in one pass and separated immediately: only the payloads
    reach the handler.
    """
    run_dir = Path(run_dir)
    pairs = stratified_sample(available_pairs(run_dir), batch, seed)

    # A stream independent of the job-order seed, so nothing about execution
    # order can correlate with presentation order.
    rng = random.Random(f"presentation::{seed}")

    payloads = []
    key = {}
    for position, pair in enumerate(pairs, 1):
        identifier = pair_id(pair["language"], pair["prompt_id"], pair["repeat"])
        arms = list(PAIR_ARMS)
        if rng.random() < 0.5:
            arms.reverse()
        texts = {}
        for slot, arm in zip(("a", "b"), arms):
            name = "%s__%s__%s__r%s.txt" % (pair["language"], pair["prompt_id"],
                                            arm, pair["repeat"])
            texts[slot] = (run_dir / "responses" / name).read_text()
        payloads.append({
            "pair_id": identifier,
            "position": position,
            "total": len(pairs),
            "a": texts["a"],
            "b": texts["b"],
        })
        key[identifier] = {
            "language": pair["language"],
            "prompt_id": pair["prompt_id"],
            "repeat": pair["repeat"],
            "A": arms[0],
            "B": arms[1],
        }
    return payloads, key


def write_key(run_dir, key):
    (Path(run_dir) / "rating-key.json").write_text(json.dumps(key, indent=2, ensure_ascii=False))


def read_key(run_dir):
    path = Path(run_dir) / "rating-key.json"
    return json.loads(path.read_text()) if path.exists() else {}


def read_verdicts(run_dir):
    path = Path(run_dir) / "ratings.jsonl"
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def remaining(run_dir, payloads):
    rated = {verdict["pair_id"] for verdict in read_verdicts(run_dir)}
    return [payload for payload in payloads if payload["pair_id"] not in rated]


def record_verdict(run_dir, verdict, rater):
    """Append one verdict immediately, so an interrupted session keeps its work.

    The record names the displayed positions, never the arms. Resolving a
    position to an arm needs `rating-key.json`, which is read only at report
    time (R14).
    """
    run_dir = Path(run_dir)
    manifest = {}
    manifest_path = run_dir / "manifest.json"
    if manifest_path.exists():
        manifest = json.loads(manifest_path.read_text())
    row = {
        "pair_id": verdict["pair_id"],
        "answers": verdict.get("answers", {}),
        "note": verdict.get("note", ""),
        "rater": rater,
        "recorded_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "run_id": manifest.get("run_id", run_dir.name),
        "questions_sha256": questions_hash(),
        "questions": [question["text"] for question in QUESTIONS],
        "harness_version": HARNESS_VERSION,
    }
    with (run_dir / "ratings.jsonl").open("a") as handle:
        handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    return row


def unblind(run_dir):
    """Join each verdict against the key, turning A and B back into arm names."""
    key = read_key(run_dir)
    joined = []
    for verdict in read_verdicts(run_dir):
        entry = key.get(verdict["pair_id"])
        if entry is None:
            joined.append({"verdict": verdict, "resolved": None,
                           "reason": "no key entry for this pair"})
            continue
        resolved = {}
        for question in QUESTIONS:
            answer = verdict.get("answers", {}).get(question["key"])
            resolved[question["key"]] = entry.get(answer, answer)
        joined.append({"verdict": verdict, "entry": entry, "resolved": resolved})
    return joined


def render_human_section(run_dir):
    """Render the reader-value leg. It shares no number with the mechanical one."""
    joined = unblind(run_dir)
    lines = ["## Human leg", ""]
    if not joined:
        lines += ["No verdict recorded yet. Run "
                  "`python3 tests/style-ab/run.py --rate <run dir>`.", ""]
        return "\n".join(lines)

    dates = sorted({row["verdict"]["recorded_at"][:10] for row in joined})
    raters = sorted({row["verdict"]["rater"] for row in joined})
    hashes = sorted({row["verdict"].get("questions_sha256") for row in joined})

    lines += [f"Pairs rated: {len(joined)}. Rater: {', '.join(raters)}.", ""]
    if len(dates) > 1:
        lines += [f"> **Warning:** these verdicts span {len(dates)} dates "
                  f"({', '.join(dates)}). One person on two different days is not "
                  "one instrument.", ""]
    if len(hashes) > 1:
        lines += ["> **Warning:** the question wording changed inside this run's "
                  "verdicts, so they are not one instrument.", ""]

    for question in QUESTIONS:
        tally = Counter(row["resolved"][question["key"]]
                        for row in joined if row.get("resolved"))
        lines += [f"**{question['text']}**", "",
                  "| Answer | Count |", "|---|---|"]
        for name in list(PAIR_ARMS) + [option[0] for option in question["options"][2:]]:
            lines.append(f"| `{name}` | {tally.get(name, 0)} |")
        one_sided = sum(tally.get(arm, 0) for arm in PAIR_ARMS)
        leader = max(tally.get(arm, 0) for arm in PAIR_ARMS) if one_sided else 0
        lines += ["", resolving_power(one_sided), ""]
        if one_sided and two_sided_probability(one_sided, leader) > 0.05:
            lines += ["This tally is inside the range a fair coin produces.", ""]

    notes = [row["verdict"]["note"] for row in joined if row["verdict"].get("note")]
    if notes:
        lines += ["**Notes from the rater.**", ""]
        lines += [f"- {note}" for note in notes] + [""]

    lines += ["The two legs share no number and are never combined. When they "
              "disagree, this leg is the one about reader value and the counters "
              "are about rule obedience.", ""]
    return "\n".join(lines)


PAGE = """<!doctype html>
<title>style A/B rating</title>
<style>
 body { font: 15px/1.5 -apple-system, system-ui, sans-serif; margin: 0; padding: 1.5rem; }
 .pair { display: grid; grid-template-columns: 1fr 1fr; gap: 1.5rem; }
 .side { border: 1px solid #999; border-radius: 6px; padding: 1rem; white-space: pre-wrap; }
 .side h2 { margin: 0 0 .5rem; font-size: 1rem; }
 fieldset { margin: 1rem 0; }
 button { font: inherit; padding: .3rem .7rem; margin-right: .4rem; }
 button.on { outline: 3px solid #06c; }
 #progress { color: #666; }
 kbd { border: 1px solid #999; border-radius: 3px; padding: 0 .25rem; }
</style>
<p id="progress"></p>
<div class="pair"><div class="side"><h2>A</h2><div id="a"></div></div>
<div class="side"><h2>B</h2><div id="b"></div></div></div>
<form id="form"></form>
<p><input id="note" placeholder="optional one-line note" size="70">
<button type="button" id="submit">submit (<kbd>enter</kbd>)</button></p>
<script>
let pairs = [], index = 0, answers = {};
const QUESTIONS = QUESTIONS_JSON;
const KEYS = KEYS_JSON;

function render() {
  if (index >= pairs.length) {
    document.body.innerHTML = "<p>All pairs rated. Close this tab and stop the server with ctrl+c.</p>";
    return;
  }
  const pair = pairs[index];
  document.getElementById("progress").textContent =
    "pair " + pair.position + " of " + pair.total;
  document.getElementById("a").textContent = pair.a;
  document.getElementById("b").textContent = pair.b;
  answers = {};
  const form = document.getElementById("form");
  form.innerHTML = "";
  QUESTIONS.forEach(function (question) {
    const set = document.createElement("fieldset");
    const legend = document.createElement("legend");
    legend.textContent = question.text;
    set.appendChild(legend);
    question.options.forEach(function (option, slot) {
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = option[1] + " (" + KEYS[question.key][slot] + ")";
      button.dataset.question = question.key;
      button.dataset.value = option[0];
      button.onclick = function () { choose(question.key, option[0]); };
      set.appendChild(button);
    });
    form.appendChild(set);
  });
  document.getElementById("note").value = "";
}

function choose(question, value) {
  answers[question] = value;
  document.querySelectorAll("button[data-question='" + question + "']").forEach(function (b) {
    b.classList.toggle("on", b.dataset.value === value);
  });
}

function submit() {
  if (QUESTIONS.some(function (q) { return !answers[q.key]; })) return;
  fetch("/api/verdict", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({pair_id: pairs[index].pair_id, answers: answers,
                          note: document.getElementById("note").value})
  }).then(function () { index += 1; render(); });
}

document.getElementById("submit").onclick = submit;
document.addEventListener("keydown", function (event) {
  if (event.target.tagName === "INPUT" && event.key !== "Enter") return;
  if (event.key === "Enter") { submit(); return; }
  QUESTIONS.forEach(function (question) {
    const slot = KEYS[question.key].indexOf(event.key);
    if (slot >= 0) choose(question.key, question.options[slot][0]);
  });
});

fetch("/api/pairs").then(function (r) { return r.json(); })
  .then(function (data) { pairs = data; render(); });
</script>
"""

# Two disjoint key rows, so a keystroke can never answer the wrong question.
KEY_BINDINGS = {"faster": ["q", "w", "e"], "missing": ["a", "s", "d"]}


def build_handler(payloads, run_dir, rater):
    """The handler closes over the payloads only. It never reads the key file."""
    page = (PAGE
            .replace("QUESTIONS_JSON", json.dumps([
                {"key": q["key"], "text": q["text"], "options": q["options"]}
                for q in QUESTIONS]))
            .replace("KEYS_JSON", json.dumps(KEY_BINDINGS)))

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _send(self, body, content_type):
            encoded = body.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def do_GET(self):
            if self.path == "/":
                self._send(page, "text/html; charset=utf-8")
            elif self.path == "/api/pairs":
                self._send(json.dumps(payloads, ensure_ascii=False),
                           "application/json; charset=utf-8")
            else:
                self.send_error(404)

        def do_POST(self):
            if self.path != "/api/verdict":
                self.send_error(404)
                return
            length = int(self.headers.get("Content-Length", 0))
            verdict = json.loads(self.rfile.read(length) or b"{}")
            record_verdict(run_dir, verdict, rater)
            print(f"  recorded {verdict.get('pair_id')}", flush=True)
            self._send(json.dumps({"ok": True}), "application/json")

    return Handler


def serve(run_dir, seed, batch=DEFAULT_BATCH, rater=None, open_browser=True):
    run_dir = Path(run_dir)
    rater = rater or os.environ.get("USER") or "unknown"

    payloads, key = prepare(run_dir, seed=seed, batch=batch)
    write_key(run_dir, key)
    todo = remaining(run_dir, payloads)
    if not todo:
        print(f"every sampled pair in {run_dir} is already rated")
        return 0

    # The payloads are renumbered so the progress counter reflects what is left
    # after a resume rather than the original batch size.
    for position, payload in enumerate(todo, 1):
        payload["position"] = position
        payload["total"] = len(todo)

    handler = build_handler(todo, run_dir, rater)
    with socketserver.TCPServer(("127.0.0.1", 0), handler) as server:
        url = f"http://127.0.0.1:{server.server_address[1]}/"
        print(f"rating {len(todo)} pair(s) as {rater}: {url}")
        print("  keys: q/w/e for the first question, a/s/d for the second, enter to submit")
        print("  stop with ctrl+c; verdicts are written as they are given")
        if open_browser:
            webbrowser.open(url)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            print("\nstopped. Re-run to continue where this left off.")
    return 0
