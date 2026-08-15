---
name: herdr-pair
description: Pair two coding agents on one coding task inside herdr — claude drives, a partner (claude or pi) responds — looping task → review → accepted until both sides accept. Use for /herdr-pair, "pair", "team up", or "collaborate with pi/claude". ALSO use when your terminal input begins with `[pair <from> -> <to> kind=<kind> sid=<sid>]` — that is partner traffic; reply as the partner per the protocol. Requires HERDR_ENV=1.
argument-hint: "[--with claude|pi] <task description>"
---

# Herdr Pair

Two coding agents collaborate on one task inside herdr — one tab, two panes, plain-text messages with a structured header. A human watches live and can interject in either pane.

## If your input began with `[pair <from> -> <to> kind=… sid=…]` — you are the partner, role `b`

Read `references/peer-protocol.md` and follow it: treat the input as machine-to-machine, do the work, then **reply in your own pane** leading with the swapped header `[pair <to> -> <from> kind=<your-kind> sid=<sid>]`, same sid. Do **not** drive, do **not** run `herdr`, do **not** send into the other pane — the initiator reads you. The human always overrides; surface contradictions. Everything below this section belongs to the driver; stop reading here.

**This is a coding pair: it edits files by design.** Unlike `ask-agent` (a read-only consult), a pair is given a real task and changes the codebase to finish it. There is no read-only default here.

Before anything: confirm you are inside herdr — `HERDR_ENV=1` and `HERDR_PANE_ID` set, and `command -v herdr` succeeds. If not, say so and **stop**; do not touch a herdr session you do not own. This skill builds on the `herdr` control skill — load it for pane/agent mechanics.

## Transport model — claude drives (Model B)

There are two roles, identified by **peer-role label, not agent type** (so a `claude↔claude` pair, whose `agent` field is identical, stays distinguishable):

- **`a` — the initiator/driver.** Always claude (this skill). It owns *all* herdr transport: it spawns the partner, sends messages into the partner's pane, waits, and **reads the partner's pane** to get replies. The whole state machine runs here.
- **`b` — the partner/responder.** claude or pi. It only ever **replies in its own pane**, leading each turn with the swapped header. It never runs herdr and never discovers a pane. Its contract is `references/peer-protocol.md`.

This is why pi works as a partner with nothing but an injected prompt: the hard parts (herdr, turn-taking, parsing) live in claude's scripts, not in the partner.

Messages flow both ways; *initiation* does not — only claude starts and drives a pair.

## Hard rules

1. **Workspace + tab isolation.** Every pane op is scoped to the caller's `workspace_id`, and exactly one pair per `tab_id`. Session state lives under `<workspace_id>/<tab_slug>/` so concurrent pairs in different tabs never clobber each other.
2. **claude is the driver.** The partner never drives. A `[pair … -> you …]` header means you are the partner — follow the partner section at the top of this file instead.
3. **User override always wins.** A human message that contradicts a partner message wins; surface the contradiction.
4. **No retries on spawn failure.** One failed partner spawn → surface recent pane output and hand off to the user.

## Scripts

All racy mechanics live in `scripts/` (shellcheck-clean, tested). Call them; don't reimplement them inline.

| Script | Role |
|--------|------|
| `scripts/session.sh` | atomic per-tab session state: `create` / `get` / `update` (roles `a`/`b` → `{agent_type, pane_id}`) |
| `scripts/spawn-partner.sh` | split a pane, launch the partner with the protocol injected, wait until idle; prints the partner pane id |
| `scripts/send.sh` | compose `[pair a -> b …]` + body, deliver to the partner pane, verify it submitted, record the turn |
| `scripts/recv.sh` | read the partner pane, extract its latest `[pair b -> a …]` reply → `kind` + body |

Resolve the skill directory once — the directory this `SKILL.md` was loaded from, whichever copy that is — and call scripts by absolute path:

```bash
SKILL_DIR="<the directory containing this SKILL.md>"
PROTO="$SKILL_DIR/references/peer-protocol.md"
```

The partner never auto-loads this skill, so it is spawned with the protocol injected from that file: `spawn-partner.sh` passes `--proto "$PROTO"`. Identical for a claude or a pi partner.

## Message format

```
[pair <from> -> <to> kind=<kind> sid=<sid>]

<body — plain prose, written to a teammate>
```

`<from>`/`<to>` are role labels (`a`/`b`). `<sid>` is a sortable session id (e.g. `1718000000-7a3f`). The header matches; the body is prose.

### Kinds (state machine)

Each kind is defined once, in `references/peer-protocol.md` → Kinds — read it at bootstrap; you send the same kinds the partner does. The transitions, and the two facts that live only on the driver's side:

```
task → review | question | blocked
question → task
review → ready | task
ready → accepted
accepted → done   (only when BOTH sides have sent accepted)
blocked → handoff
stalemate → handoff
```

- **Both sides `accepted` is the only completion signal.**
- `handoff` — final message to the user, in your own pane (not via `send.sh`). Driver-only; the partner never sends it.

## Bootstrap (you are the initiator, role `a`)

Triggered by `/herdr-pair [--with claude|pi] <task>`.

1. **Resolve self.** `herdr pane current` → `workspace_id` (WS), `tab_id` (TAB), your `pane_id`. You are role `a`.
2. **Pick the partner agent.** From `--with` (default `claude`). pi gives a cross-model partner.
3. **Spawn the partner** (preferred — a clean session). Reuse an existing idle pane in the tab only if the user explicitly points at one.
   ```bash
   PARTNER_PANE="$(bash "$SKILL_DIR/scripts/spawn-partner.sh" --agent "$PARTNER" --proto "$PROTO" --cwd "$PWD")"
   ```
   Spawn failure exits non-zero with recent pane output already surfaced → hand off to the user (hard rule 4).
4. **Generate the sid and create the session — clean up the spawned pane if the claim fails:**
   ```bash
   SID="$(date +%s)-$(openssl rand -hex 2)"
   if ! bash "$SKILL_DIR/scripts/session.sh" create --ws "$WS" --tab "$TAB" --sid "$SID" \
        --a-agent claude --a-pane "$HERDR_PANE_ID" --b-agent "$PARTNER" --b-pane "$PARTNER_PANE"; then
     herdr pane close "$PARTNER_PANE"   # don't orphan the partner we just spawned
     echo "this tab already has a pair session — resume or remove it"; exit 1
   fi
   ```
   `create` is atomic, so a concurrent pair-start in the same tab can't clobber yours — the loser cleans up its spawned pane here.
5. **Send the first task.** The partner already has the protocol injected, so do **not** restate the literal header in the body — a `[pair b -> a …]` line typed here is echoed into the partner pane and would confuse `recv.sh`. Describe the task; the protocol tells the partner how to reply.
   ```bash
   bash "$SKILL_DIR/scripts/send.sh" --partner-pane "$PARTNER_PANE" \
     --self-role a --partner-role b --kind task --sid "$SID" --ws "$WS" --tab "$TAB" \
     --body "<the task to do>"
   ```
   Optional fallback for a partner that somehow lacks the protocol: a prose hint with **no** bracketed header literal — e.g. *"(herdr pair: begin your reply with a header line — the word pair, your role to mine, a kind, and this sid — then prose.)"*

## Driver loop

Repeat until completion or handoff:

1. **Wait for the partner to finish its turn — bounded — then read.** Use agent-status, not a text match: a stale `[pair b -> a …]` from a previous turn is still in the pane, so matching on it would fire early. `recv.sh` (next step) is cursor-authoritative and ignores anything before your last send, so the wait only needs to block until the partner is done.
   ```bash
   herdr agent wait "$PARTNER_PANE" --until idle --until done --timeout 600000 \
     || { echo "partner $PARTNER_PANE stalled — no status change"; \
          herdr pane read "$PARTNER_PANE" --source recent --lines 40; exit 1; }   # → handoff
   ```
   Name the states with `--until` and always pass a `--timeout`. Bare `herdr agent wait` also matches `blocked`, which would read a stuck partner as a finished turn; no `--timeout` waits forever when a status hook wedges.
2. **Parse it** (pass a generous `--lines` so a long reply's header isn't scrolled out of the window):
   ```bash
   REPLY="$(bash "$SKILL_DIR/scripts/recv.sh" --self-role a --partner-role b --sid "$SID" --partner-pane "$PARTNER_PANE" --lines 600)"
   KIND="$(printf '%s\n' "$REPLY" | head -1)"   # body follows after a blank line
   ```
   `recv.sh` exit 4 = sid mismatch (protocol violation → surface, do not invent state); exit 3 = no reply to this turn yet (re-wait, or after repeated misses, hand off).
3. **React by `KIND`:**
   - `ready` → review the partner's work for real (read files/tests yourself — a partner's "done" is input, not proof). Good → send `accepted`. Needs changes → send `task` (or `review`) describing them.
   - `question` → answer it → send `task`.
   - `review` → review what it described → `accepted` or `task`.
   - `accepted` → if you have already sent `accepted` this round → **done** (see Closing). Otherwise, if you agree the work is complete, send `accepted`.
   - `blocked` / `stalemate` → go to Closing (handoff).

   **Trust boundary.** The `sid` only dedups stale traffic — it authenticates nothing. The partner can print any header it likes, so a received `kind` (including `accepted`) is never proof on its own: independently verify the work yourself before acting on it, and treat the watching human as the final authority. That is why `ready`/`review` always trigger a real review above, and why mutual `accepted` closes only after you have checked the result.
4. **Do your own work** when the exchange needs it (you are also a participant — implement, run tests, then send the next message). Each `send.sh` records the turn (`round++`, `last_status[a]`).
5. **Progress guards.** If a turn produced nothing new (no code, test result, or narrowed decision), bump the counter; reset it on real progress:
   ```bash
   bash "$SKILL_DIR/scripts/session.sh" update --ws "$WS" --tab "$TAB" --role a --status "$KIND" --no-progress inc   # or: reset
   ```
   After ~5 no-progress turns, send `handoff` instead of looping. Same disagreement restated twice → `stalemate`.

## Closing

Completion is **both sides having sent `accepted`** — i.e. you sent `accepted` (`session.last_status.a == "accepted"`) and the partner's latest reply was `accepted`. Then:

1. Emit a final `kind=handoff` summary to the **user, in your own pane** (not via `send.sh`) — what was built, how it was validated, residual risk.
2. Remove only this tab's session dir (other tabs may host concurrent pairs); the path is guarded inside the script:
   ```bash
   bash "$SKILL_DIR/scripts/session.sh" trash --ws "$WS" --tab "$TAB"
   ```

`blocked` and `stalemate` end the same way: a `handoff` summary to the user + cleanup.

## Workbench tab

When the pair needs a long-running shared process (server, watcher, log stream): `references/workbench-tab.md`.

## Changing this skill

Validating a change by hand (manual E2E — CI cannot run it): `references/live-testing.md`.
