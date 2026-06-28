# Workbench tab (lazy, optional)

A separate tab in the same workspace where long-running shared processes (servers, dev watchers, log streams) live so the user can flip to it and watch. It does not exist by default — create it only when an agent first needs to run such a process. One-shot test runs don't need it; use the agent's own pane or a temporary split.

The workbench tab is shared by the pair, but the bookkeeping for it stays in the pair's **own** session file — the one under the pair's tab slug, not the workbench tab's.

## Creating the workbench (once per pair)

```bash
WB="$(herdr tab create --workspace "$WS" --label workbench \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["tab"]["tab_id"])')"
```

Then record `workbench.tab_id = $WB` in the pair's session file. `session.sh` owns the session schema and its atomic-write discipline (temp file + `mv`), but it only mutates the turn-taking fields (`round`, `last_status`, `no_progress_count`) — the optional `workbench` block is updated inline with the **same** read → mutate → temp-file → `os.replace` pattern so a racing partner never sees a half-written file:

```bash
TAB_SLUG="${TAB_ID//:/_}"
SESSION="$HOME/.herdr-coworkers/$WS/$TAB_SLUG/session.json"   # honors $HERDR_COWORKERS_DIR if set
WB="$WB" python3 - "$SESSION" <<'PY'
import json, os, sys
path = sys.argv[1]
with open(path) as f: s = json.load(f)
s.setdefault("workbench", {})["tab_id"] = os.environ["WB"]
tmp = f"{path}.tmp.{os.getpid()}"
with open(tmp, "w") as f: json.dump(s, f, indent=2)
os.replace(tmp, path)
PY
```

## Running processes inside the workbench

Split panes inside the workbench tab for whatever you need (server, logs, etc.). Record `workbench.server_pane` and `workbench.logs_pane` in the session file via the same atomic update so the partner can find them without rediscovering.

## Reading workbench output

```bash
herdr pane read <pane> --source recent-unwrapped --lines N
```

Re-verify recorded pane IDs with `herdr pane get` before relying on them — public pane IDs can compact when panes close.
