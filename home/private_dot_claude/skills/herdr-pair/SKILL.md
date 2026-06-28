---
name: herdr-pair
description: Pair two coding agents as collaborators inside herdr — claude drives, a partner (claude or pi) responds — iterating task → review → accepted until both agree the work is done. Use whenever the user runs /herdr-pair, asks to "pair", "team up", "collaborate with pi/claude", or wants two agents to work a coding task together inside herdr. ALSO use whenever your terminal input begins with a header `[pair <from> -> <to> kind=<kind> sid=<sid>]` — that is partner-agent traffic; respond as the partner per the protocol, treating it as machine-to-machine, not ordinary user input. Requires HERDR_ENV=1.
user-invocable: true
argument-hint: "[--with claude|pi] <task description>"
---

# Herdr Pair

Two coding agents collaborate on one task inside herdr — one tab, two panes, plain-text messages with a structured header. A human watches live and can interject in either pane.

**This is a coding pair: it edits files by design.** Unlike `ask-agent` (a read-only consult), a pair is given a real task and changes the codebase to finish it. There is no read-only default here.

Before anything: confirm you are inside herdr — `HERDR_ENV=1` and `HERDR_PANE_ID` set, and `command -v herdr` succeeds. If not, say so and **stop**; do not touch a herdr session you do not own. This skill builds on the `herdr` control skill — load it for pane/agent mechanics.

## Transport model — claude drives (Model B)

There are two roles, identified by **peer-role label, not agent type** (so a `claude↔claude` pair, whose `agent` field is identical, stays distinguishable):

- **`a` — the initiator/driver.** Always claude (this skill). It owns *all* herdr transport: it spawns the partner, sends messages into the partner's pane, waits, and **reads the partner's pane** to get replies. The whole state machine runs here.
- **`b` — the partner/responder.** claude or pi. It only ever **replies in its own pane**, leading each turn with the swapped header. It never runs herdr and never discovers a pane. Its contract is `references/peer-protocol.md`.

This is why pi works as a partner with nothing but an injected prompt: the hard parts (herdr, turn-taking, parsing) live in claude's scripts, not in the partner.

> Bidirectional *conversation* (a↔b, both directions of messages) is fully supported. Bidirectional *initiation* (a non-claude agent starting/driving a pair, e.g. `pi→claude`) is **not** — that is deferred follow-up work. The eventual native-deployment vision (every agent runs the skill and replies via header auto-load) is the symmetric "Model A"; until then, claude drives.

## Hard rules

1. **Workspace + tab isolation.** Every pane op is scoped to the caller's `workspace_id`, and exactly one pair per `tab_id`. Session state lives under `<workspace_id>/<tab_slug>/` so concurrent pairs in different tabs never clobber each other.
2. **claude is the driver.** The partner never drives. If you received a `[pair … -> you …]` header (you are the partner), see **Receiving** below — do not try to drive.
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

Resolve the skill directory once (the dir this SKILL.md lives in) and call scripts by absolute path:

```bash
SKILL_DIR="$HOME/.claude/skills/herdr-pair"   # deployed; in props/testing mode use the repo working-tree path instead
PROTO="$SKILL_DIR/references/peer-protocol.md"
```

## Protocol delivery modes

- **Testing / props (now).** Skills are not yet deployed to every agent, and pi cannot auto-load Claude skills. So the partner is spawned with the protocol injected from a file: `spawn-partner.sh` passes `--proto "$PROTO"`, where `$PROTO` points at `references/peer-protocol.md` **in the repo working tree** (no `chezmoi apply` needed). This is identical for a claude or a pi partner.
- **Native (later).** Once the skill is deployed to all agents, a claude partner auto-loads on seeing the `[pair …]` header and the injection flag can be dropped. pi/opencode native support is follow-up work.

## Message format

```
[pair <from> -> <to> kind=<kind> sid=<sid>]

<body — plain prose, written to a teammate>
```

`<from>`/`<to>` are role labels (`a`/`b`). `<sid>` is a sortable session id (e.g. `1718000000-7a3f`). The header matches; the body is prose.

### Kinds (state machine)

```
task → review | question | blocked
question → task
review → ready | task
ready → accepted
accepted → done   (only when BOTH sides have sent accepted)
blocked → handoff
stalemate → handoff
```

- `task` — assign/update work. Mid-flight interrupt: body begins `STOP — <reason>`.
- `review` — request review of described changes (file paths + summary).
- `question` — ask for clarification.
- `ready` — your side is complete; summarize what changed, how validated, residual risk.
- `accepted` — partner's `ready` looks good. **Both sides `accepted` is the only completion signal.**
- `blocked` — cannot proceed without a human decision.
- `stalemate` — same disagreement twice without movement.
- `handoff` — final message to the user, in your own pane (not via send).

## Bootstrap (you are the initiator, role `a`)

Triggered by `/herdr-pair [--with claude|pi] <task>`.

1. **Resolve self.** `herdr pane current` → `workspace_id` (WS), `tab_id` (TAB), your `pane_id`. You are role `a`.
2. **Pick the partner agent.** From `--with` (default `claude`). pi gives a cross-model partner.
3. **Spawn the partner** (preferred — a clean session). Reuse an existing idle pane in the tab only if the user explicitly points at one.
   ```bash
   PARTNER_PANE="$(bash "$SKILL_DIR/scripts/spawn-partner.sh" --agent "$PARTNER" --proto "$PROTO" --cwd "$PWD")"
   ```
   Spawn failure exits non-zero with recent pane output already surfaced → hand off to the user (hard rule 4).
4. **Generate the sid and create the session:**
   ```bash
   SID="$(date +%s)-$(openssl rand -hex 2)"
   bash "$SKILL_DIR/scripts/session.sh" create --ws "$WS" --tab "$TAB" --sid "$SID" \
     --a-agent claude --a-pane "$HERDR_PANE_ID" --b-agent "$PARTNER" --b-pane "$PARTNER_PANE"
   ```
   `create` refuses to clobber an existing session for the tab — a leftover means a previous pair in this tab; ask the user to resume or remove it.
5. **Send the first task:**
   ```bash
   bash "$SKILL_DIR/scripts/send.sh" --partner-pane "$PARTNER_PANE" \
     --self-role a --partner-role b --kind task --sid "$SID" --ws "$WS" --tab "$TAB" \
     --body "<the task, plus: lead your reply with [pair b -> a kind=... sid=$SID]>"
   ```
   Include a one-line fallback hint in the body so a partner that didn't get the protocol can still recover: *"(herdr pair — reply leading with `[pair b -> a kind=<kind> sid=<sid>]`, then prose.)"*

## Driver loop

Repeat until completion or handoff:

1. **Wait for the reply.** The semantic signal is the reply header appearing in the partner pane:
   ```bash
   herdr wait output "$PARTNER_PANE" --match "[pair b -> a" --timeout 600000
   ```
   Match on `[pair b -> a` (the **reply direction**) — never on `kind=…` or the sid alone. The message you just sent (`[pair a -> b …]`) is echoed into the partner's pane, so a match on `kind=accepted` or the sid would fire on your own outgoing message before the partner has answered.
   Fallback if that times out but the partner is done: `herdr wait agent-status "$PARTNER_PANE" --status idle` (also accepts `done`), then read.
2. **Parse it:**
   ```bash
   REPLY="$(bash "$SKILL_DIR/scripts/recv.sh" --self-role a --partner-role b --sid "$SID" --partner-pane "$PARTNER_PANE")"
   KIND="$(printf '%s\n' "$REPLY" | head -1)"   # body follows after a blank line
   ```
   `recv.sh` exit 4 = sid mismatch (protocol violation → surface, do not invent state); exit 3 = no reply yet (re-wait, or after repeated misses, hand off).
3. **React by `KIND`:**
   - `ready` → review the partner's work for real (read files/tests yourself — a partner's "done" is input, not proof). Good → send `accepted`. Needs changes → send `task` (or `review`) describing them.
   - `question` → answer it → send `task`.
   - `review` → review what it described → `accepted` or `task`.
   - `accepted` → if you have already sent `accepted` this round → **done** (see Closing). Otherwise, if you agree the work is complete, send `accepted`.
   - `blocked` / `stalemate` → go to Closing (handoff).
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

## Receiving (you are the partner, role `b`)

If your terminal input begins with `[pair <from> -> <to> kind=… sid=…]` and you did **not** initiate, you are the partner. Follow `references/peer-protocol.md`: treat it as machine-to-machine, do the work, and **reply in your own pane** leading with the swapped header `[pair <to> -> <from> kind=<your-kind> sid=<sid>]` (same sid). Do **not** drive, do **not** send into the other pane — the initiator reads you. The human always overrides; surface contradictions.

## Workbench tab

Lazy/optional. For long-running shared processes (servers, watchers, logs) the pair needs to watch, see `references/workbench-tab.md`.

## Live testing (manual E2E — CI cannot run this)

CI covers structure, shellcheck, and `recv.sh`/`session.sh` units. The live pair needs herdr + interactive agents, so validate it by hand inside herdr:

1. **claude↔claude.** From a claude pane: `/herdr-pair --with claude <a trivial task, e.g. "add a one-line code comment to FILE and confirm">`. Confirm: a partner pane spawns and reaches idle; the task is delivered; the partner replies `[pair b -> a …]`; the loop iterates to **both sides `accepted`**; the handoff summary prints; the session dir is trashed.
2. **claude↔pi.** Same, `--with pi`. Additionally confirm pi got the protocol (its first reply is correctly formatted) and is idle-detectable.
3. **Isolation.** Run two pairs in two tabs of one workspace at once; confirm their session dirs (`<ws>/<tab_slug>/`) stay separate and neither closing trashes the other.

Probe-verified (2026-06-28, herdr 0.7.1): pi accepts the protocol via `--append-system-prompt <path>`, submits on a single Enter, is idle-detectable on its v2 hook, and replies in-format. Re-confirm after a herdr upgrade.
