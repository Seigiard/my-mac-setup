"""Write one adjudicator prompt per case from the pilot template, mapping each case file's base..head to its repository."""
import json, glob, os
H = os.path.expanduser("~/.local/state/revmux-bench/576-holdout")
TEMPLATE = "/Users/andrew.b/Projects/my-mac-setup/docs/benchmarks/revmux-harness/pilot-408/adjudication/prompt-template.md"
repos = {(c["base"], c["head"]): c["repository"] for c in (json.load(open(f)) for f in glob.glob(f"{H}/cases/*.json"))}
for path in sorted(glob.glob(f"{H}/adjudication/in/case-*.json")):
    d = json.load(open(path)); n = os.path.basename(path)[:-5]; repo = repos[(d["base"], d["head"])]
    prompt = (open(TEMPLATE).read().replace("PACKET", path).replace("CASE_RANGE", f"{d['base']}..{d['head']}").replace("REPO_PATH", repo)
              .replace("BASE..HEAD", f"{d['base']}..{d['head']}").replace("HEAD:<path>", f"{d['head']}:<path>").replace("OUTPUT_PATH", f"{H}/adjudication/out/{n}.json"))
    assert "PACKET" not in prompt and "REPO_PATH" not in prompt and "OUTPUT_PATH" not in prompt
    open(f"{H}/adjudication/prompt-{n}.md", "w").write(prompt); print(n, repo, d["base"][:8], d["head"][:8])
