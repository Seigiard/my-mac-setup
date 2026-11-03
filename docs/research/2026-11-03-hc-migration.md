---
title: Migrate agent-to-agent communication from the herdr TUI CLI to hc - Issue 596 research
type: research
date: 2026-11-03
topic: hc-migration
status: complete
execution: read-only-source-research-plus-hc-trials-in-own-terminals
---


# Migrate agent-to-agent communication from the herdr TUI CLI to hc: issue 596

## Summary

The Herdr app runs terminals through herdr-core (`hc` 0.1.17). Every agent-to-agent tool in this repository (`herdr-child`, `herdr-peer`, `herdr-peer-alias`, `herdr-resource-tree`, the `herdr` and `ask-in-herdr` skills, the `herdr-resource-context` and `herdr-worktree-identity` hooks) is guarded by `HERDR_ENV=1` or `HERDR_PANE_ID` and calls the TUI's `herdr agent|pane|tab|workspace|api` commands. App terminals receive only `HC_SCOPE`, `HC_TERMINAL_ID` and `HC_TERMINAL_SOCKET`, so all of it is already inert inside the app. `hc` covers the transport natively: child launch with a first task, messages tagged `<hc from="t7 name">`, parent edge, waiting on children, notes on blocked/error/exit, kill and rm. It does not carry message kinds, color-animal addresses, the `[peer-message v1]` marker, the supervision generation and receipt machinery, posture flags, or creator attribution for panes and tabs. Most of those should be dropped: hc notes and tags make them redundant. Two things stay as prose in the contracts (the end-the-turn rule, the decision brief) and one or two stay as thin helpers (a reap guard, an ask-the-parent one-liner). The old `herdr server` still runs under launchd with three plugin daemons and one TUI client in a Ghostty window; it can be retired after the sidebar (#594), worktree setup discovery and `herdr-run` move off it.

## 0. Sources and evidence rules

- `hc --skill` (manual, 0.1.17), `hc --help`, `hc <cmd> --help`, `hc schema` (`terminal.run`, `terminal.send`, `terminal.wait`, `Terminal` fields). Quoted as `hc --skill § <section>`.
- `herdr-app --skill` for window arrangement.
- Deployed contracts: `~/.claude/shared/child-agent-contract.md` (source `home/private_dot_claude/shared/child-agent-contract.md`) and `~/.claude/shared/peer-message-contract.md`.
- Repository files are cited as `path:line`. Line numbers are from the checkout at branch `herdr-app-tab-names-602` on 2026-11-03.
- Trials ran in terminals named `probe596*` only; all were killed and removed. The full log is in appendix A. Anything not in appendix A is marked **untested**.
- `~/.config/herdr-core/config.toml` and `~/.config/herdr-core/templates/` do not exist on this machine; `hc templates` returns `{"templates":[]}`. Template behavior is therefore cited from the manual only and marked **untested**.

## 1. Coverage table

Each row is one element of the current contracts. "hc native" names the hc feature that carries it today. "Lost" names what hc does not carry.

| # | Current element | Where it is defined | hc native | Lost | Evidence |
|---|---|---|---|---|---|
| 1 | `send` message kind | `peer-message-contract.md:20` ("`send` is a notification or assignment"); `executable_herdr-peer:63-64` | `hc send <t> "<text>"` pastes text and presses Enter. Delivered to an agent as `<hc from="t7 review">…</hc>`. | Nothing structural. The receiver gets sender address and name, not a kind. | `hc --skill § Talk, wait, and collect results`; `hc send --help`; trial A3 (`hc send probe596-cat "hello from t1 trial"` → `{"started":null,"status":null,"turn":0}`, text appeared in `hc read`). Tag shape on an agent terminal: **untested** (t1 is the orchestrator). |
| 2 | `ask` message kind (request a decision, do not wait, end the turn) | `peer-message-contract.md:21-22`; `child-agent-contract.md:242-246` (child duties 1, 5) | Same transport as 1. The core adds a `reach="hc send t3 when done or stuck"` attribute when a parent gives a child a task, which is the reply address. A reply arrives "as your next input". | The `kind=ask` field. hc has no "question" message type; a question is text. | `hc --skill § Talk, wait, and collect results` ("If you receive: `<hc from="t3 lead" reach="hc send t3 when done or stuck">`… Report with `hc send t3`"); `hc wait` `reason: message` ("the message arrives as your next input"). |
| 3 | `reply` message kind | `peer-message-contract.md:22,31`; `herdr-child reply` (`herdr-child-continuation.sh:552-563`, markers `[parent-reply v1/v2]`) | `hc send <t> "<decision>"`. `hc send` refuses a `blocked` target unless `--force`. | `kind=reply` and the `[parent-reply vN]` markers. | `hc --skill § Status, recovery, and cleanup` ("`send` refuses unless `--force`; don't use it to bypass a permission decision"); `hc send --help` (`--force`, `--if idle|working`). Trial A5: `hc send --if idle` on a silent program → exit 10 `status_mismatch`. |
| 4 | `[peer-message v1 from=<alias> pane=<id> kind=…]` marker | `peer-message-contract.md:24-29`; `executable_herdr-peer:63` | `<hc from="<address> <name>">…</hc>` wraps every message the core types into an agent. `notes = false` in `~/.config/herdr-core/config.toml` turns the tags off. | The `pane=` coordinate (hc has no panes; the address is `t7`) and `kind=`. | `hc --skill § Talk, wait, and collect results`; `hc --help` ("notes = false: hc types nothing on its own (no notes to parent agents, no <hc> tags on messages)"). |
| 5 | Color-animal aliases as addresses | `peer-message-contract.md:4-5` ("`jade-rabbit`"); `GLOSSARY.md:50-51` (Peer address); `executable_herdr-peer-alias:1-8`; `executable_herdr-child:12-26` (allocator `herdr-pane-labels --alias-candidates`) | Addresses are `t7`, a `--name` (unique among live terminals, 1-32 of `a-z 0-9 - _ .`), or `machine/t7`. `hc ls` lists all live terminals with `agent`, `status`, `where`. The app names tabs with color-animal words (`herdr-app ls` → tab `olive-dogo`) and writes a `where` label on terminals (`"where":"my-mac-setup / olive-dogo"`), but that is a tab name, not a terminal address. | Alias as the address. `herdr-peer list` (alias, kind, status) becomes `hc ls`. The `herdr-pane-labels` allocator has no hc counterpart. | `hc --skill` preamble ("`<t>` below means an ID (`t7`), a name (`review`), or `machine/t7`"); `hc run --help` (`--name`); trial A1 (`hc get t1` → `name: null`, `labels.where: "my-mac-setup / olive-dogo"`); `herdr-app ls` output (tab `name: "olive-dogo"`, terminal `name: null`). |
| 6 | End-the-turn rule after `ask` | `peer-message-contract.md:21-22,31-32`; `child-agent-contract.md:246` | Not a feature; hc assumes it. `hc wait --children any` returns `reason: message` when a message reaches the parent while it works; `hc send --wait` is the attached alternative. Notes and messages are typed into the terminal regardless of whether anybody is waiting. | Nothing, but nothing enforces it either. It stays prose. | `hc --skill § Talk, wait, and collect results` ("Keep doing useful work while children work"; "`reason: message`: the message arrives as your next input, possibly late"); trial A6 (`hc wait --children any` returned `reason: children` 3.0 s after a child exited). |
| 7 | Child launch with a first task | `herdr-child start` (`herdr-child-launch.sh:5-67` flags `--kind --posture --cwd --model --effort --skills --agent --prompt --prompt-file --direction --tab --label --wait --detach --timeout --supervision-timeout`); preamble `herdr-child-launch.sh:722-728`; `child-agent-contract.md:7-13` (`HERDR_CHILD_LAUNCH=1`, `HERDR_CHILD_PARENT_PANE`) | `hc run --bg --name <n> --cwd <dir> <agent-or-template> "<task>"`. Templates in `~/.config/herdr-core/templates/<name>.md` carry `name`, `description`, `command` (with model) and a body that is prepended to the task. `first_message.sent` reports whether the task was delivered. The child gets `HC_TERMINAL_ID`; its `parent` field is set once at start. | `--posture ro|rw` (tool denial), `--kind` validation, `--skills`, `--effort`, opencode `--agent`: all become template `command` lines. `--tab|--direction|--label` placement: hc "does not arrange windows"; use `herdr-app do tab.new --argv --task` or `pane.split`. `--wait|--detach`: `hc run` without `--bg` waits; with `--bg` the parent waits later. `--supervision-timeout`: `--timeout` (default 180 s) is a check-in, not a deadline. | `hc --skill § Delegate a task`; `hc run --help`; `hc schema` `terminal.run` params (`argv`, `cwd`, `env`, `labels`, `name`, `no_notify`, `no_parent`, `outlive_parent`, `parent`, `rm`, `timeout`, `wait`); `herdr-app --skill` ("Use `herdr-app` only to change what the person sees"); trial A1 (`hc run --bg --name probe596 --cwd /tmp sh -c …` → `{"address":"t8","parent":"t1",…}`; `herdr-app ls` showed t9/t10 under t1 as `sub_agents`, not as tabs). Template run: **untested** (no templates installed). |
| 8 | Watcher and detached supervision | `herdr-child-watcher.sh` (499 lines; polls `herdr agent wait`/`agent get`/`pane get`, delivers `[child-supervision v1 generation=… event=timeout|settled-seq|blocked-seq|child-gone]` with per-event receipts, lines 85-115, 458); `child-agent-contract.md:217-238,250-259`; `GLOSSARY.md:24-25` | The core itself types a note into the parent when a child blocks, errors or exits (`notify` field, `--no-notify`). `hc wait --children all|any` with a 180 s check-in. Status comes from OSC 7501 (`idle|working|done|blocked|error`), never from screen text. The note is typed whether or not the parent is waiting, so it survives the end of the parent's turn. | Generation nonce, receipts and duplicate suppression, the `supervised` TTL label, `settled-seq` vs `timeout` events, `child-gone` (hc keeps finished terminals until `rm`; `reason: exited|killed|holder_lost…`). Exactly-once delivery is not promised by either side (`child-agent-contract.md:262`). | `hc --skill § Talk, wait, and collect results` ("hc itself notifies you when a child cannot report (blocked, error, exited)"); `§ Status, recovery, and cleanup`; `hc schema` `Terminal.notify`, `Terminal.reason`; trial A1/A2 (probe596 had `notify: true`; after it exited the orchestrator's screen read "автоматическая заметка от herdr-core… t8 probe596 завершился с кодом 0", `hc read t1 --lines 0`); trial A6 (`wait --children any` → `{"children":[{"terminal":"t10","ended":true,"exit_code":7,"reason":"exit"}],"reason":"children"}`). Note text for `blocked`/`error`: **untested**. |
| 9 | Continuation (`herdr-child prompt --wait|--detach`, `reply` re-arms supervision) | `herdr-child-continuation.sh:36-160,420-470`; `child-agent-contract.md:186-215` | `hc send <t> "<task>"`; `hc send --wait <t>` waits for the turn that send started (`not_started` means it has not begun); `--if idle` guards against sending into a working agent. | The generation handshake and the baseline `state_change_seq` comparison. Whether a send to a `working` agent is queued (the TUI queued it, `child-agent-contract.md:19-43`): **untested** for hc. | `hc --skill § Talk, wait, and collect results`; `hc send --help`; `hc schema` `terminal.send` (`caller` "so a bare wait from the same caller waits for this send's turn"); trial A4 (`hc send --wait --timeout 5` on `cat` → `wait.reason: "timeout"`, exit 0). |
| 10 | Reaping (`herdr-child reap --to --pane`: verify pair, invalidate supervision, keep focused/working/waiting panes, close tab only when owned) | `herdr-child-reap.sh:5-194`; `child-agent-contract.md:237`; `herdr/SKILL.md:71` | `hc kill <t>; hc rm <t>`; `run --rm` removes on exit; children end when the parent's program ends unless `--outlive-parent`; "Only clean up terminals you started". | The status guard ("preserve focused, working, or decision-waiting panes"), the ownership token on the tab, pair verification. An `hc run --bg` child is not a tab, so tab cleanup disappears (observed). | `hc --skill § Run programs`, `§ Status, recovery, and cleanup`; trial A7 (`hc kill probe596-cat` → `state: finished, reason: killed, signal: 1`; `hc rm` → `{"removed":"t9"}`; second `rm` → exit 3 `not_found`). `hc rm` on a live terminal: **untested**. |
| 11 | Resource tree and parent edge | `executable_herdr` PATH wrapper + `herdr-resource-tree.py` (1634 lines; SQLite `agent_parent_edges`, lines 219-232, 388-433); `docs/herdr-resource-tree.md:1-10`; ADR-0017; `GLOSSARY.md:8-23`; hook `executable_herdr-resource-context.sh:85` (`--context --caller-agent claude --caller-session-id`) | `Terminal.parent` ("The terminal that started it (`t3`), set once at start"); `hc ls` (all live terminals), `hc get`, `hc events --children-of <t>`, `hc wait --children`. The app nests `sub_agents` under the parent terminal (`herdr-app ls`). | Creator attribution for spaces, tabs and panes made through `herdr-app` (the wrapper intercepts only the `herdr` binary, ADR-0017 § Decision). The injected "Agent resource context" projection at SessionStart/UserPromptSubmit/PostToolBatch. The repository's own parent edge store (`record-child`). | `hc schema` `Terminal.parent`; `hc events --help` (`--children-of`, `--label`); trial A1 (`"parent":"t1"` on every probe); `herdr-app ls` (`sub_agents: ["t10","t9"]`). |
| 12 | Decision-brief hand-off (child asks the parent with a brief; parent replies) | `child-agent-contract.md:242-243` ("Structure the body as a decision brief: read `~/.claude/shared/decision-brief.md`"); preamble `herdr-child-launch.sh:723` ("run: herdr-child ask '<decision brief>'. Do not open an interactive question dialog") | A child reports with `hc send $PARENT "<result or blocker>"`. The parent address is in the `reach` attribute of the task message, or `hc get $HC_TERMINAL_ID` → `parent`. | The instruction itself. hc's own model for `blocked` is "a person is needed (permission or a question): read the screen and ask your user", which is the opposite of the contract's "ask the parent, never open a dialog". | `hc --skill § Status, recovery, and cleanup`; `hc --skill § Talk, wait, and collect results` ("Report with `hc send t3 "<result or blocker>"` when done or stuck, not just to acknowledge"). |
| 13 | Blocked and exit notes to the parent (`blocked=waiting` TTL state label, `child-gone`) | `child-agent-contract.md:95-113,217-225`; `herdr-child-watcher.sh:98-104` | Native: the core notes `blocked`, `error`, `exited` into the parent; `hc get <t>` shows `status`, `state`, `exit_code`, `reason`. `--no-notify` suppresses the exit note; `notes = false` suppresses everything. | TTL'd state labels. hc labels (`hc label <t> k=v`) have no TTL. | `hc --skill § Talk, wait, and collect results`; `hc label` trial A1 (`labels: {"owner":"t596","role":"probe"}`); `hc schema` `terminal.label` (`key=` removes). |

What the app's terminals get: `env` in t1 shows `HC_SCOPE`, `HC_TERMINAL_ID=t1`, `HC_TERMINAL_SOCKET=~/.local/state/herdr-core/default/default.sock`; no `HERDR_*` variable. `hc exec env | grep -i herdr` returns only `__CFBundleIdentifier=dev.herdr.app` (exec runs outside a terminal, so it has no `HC_TERMINAL_ID`). Consequently:

- `herdr-child` exits 1 at `require_herdr` (`herdr-child-runtime.sh:44-46`).
- `herdr-peer` exits 1 without `HERDR_PANE_ID` (`executable_herdr-peer:51`).
- `ask.sh` refuses (`ask-in-herdr/SKILL.md:29`; `scripts_test.sh:2355`).
- The Claude hooks exit 0 silently (`executable_herdr-resource-context.sh:6`, `executable_herdr-worktree-identity-hook.sh:10`, `~/.claude/hooks/herdr-agent-state.sh:20-22`), as do the Pi and OpenCode plugins (`herdr-resource-context.ts:75`, `opencode/plugins/herdr-resource-context.ts:51`, both `herdr-worktree-identity.ts:29/74`).
- `.zshrc`'s `_herdr_report_machine` is skipped (`home/dot_zshrc.tmpl:159`).
- `herdr-run` takes its non-herdr branch (`executable_herdr-run:127,398`).

## 2. Disposition of each uncovered element

| Element | Decision | Form | Reason |
|---|---|---|---|
| Message kinds `send|ask|reply` | Drop the field. Keep the behavior as two sentences in the contract. | Prose in the rewritten contract: "A question to another agent is an ordinary `hc send`. After you send a question, end the turn; the answer arrives as your next input. Answer only what was asked." | The receiver already knows the sender (`<hc from>`), and the body says whether it is a question. A kind field was needed because the TUI prompt carried no sender. Two scripts and two contracts exist today only to add that field (`executable_herdr-peer:63`). |
| `[peer-message v1]` marker | Drop. | None. `<hc from="t7 name">` is the marker; `notes` stays at its default (on). | The core writes the tag; a second marker inside the body would be a duplicate. |
| Color-animal aliases as addresses | Drop as addresses. Keep as display names in the app (#594). | Children get a task name via `--name` (`review`, `fix-auth`), as `hc --skill § Delegate a task` recommends. Peers are addressed by `t7` from `hc ls`. | Names are unique among live terminals only (`hc run --help`), so a name is an address only while that terminal lives; `t7` is "this terminal forever on this core" (`hc schema` `Terminal.address`). The allocator (`herdr-pane-labels`) is a TUI plugin that cannot see hc terminals. #594 notes the app has no color-animal labels for agents yet; that is a sidebar question, not an addressing one. |
| End-the-turn rule | Keep as prose. | Contract sentence plus the same sentence in the template body for children. | hc cannot enforce it, and `docs/solutions/architecture-patterns/child-initiated-callback-over-in-turn-supervision.md` § Principle 1 still holds: a wait inside the parent's turn dies with the turn. hc's notes make the callback the default: they are typed in whether or not the parent waits. |
| Child launch options (`--posture`, `--kind`, `--model`, `--effort`, `--skills`, `--agent`) | Move to herdr-core templates. | `home/private_dot_config/herdr-core/templates/<role>.md` (deployed to `~/.config/herdr-core/templates/`): `reviewer` (claude, read-only via `--disallowedTools Edit,Write,NotebookEdit,AskUserQuestion`), `implementer` (opencode rw), `consult-pi`, plus whatever `tdd/dispatch.md` tiers need. Body = child duties preamble (today `herdr-child-launch.sh:722-728`) with `hc send $PARENT` instead of `herdr-child ask`. Codex templates carry `--no-daemon`. | The manual names templates as the place for role instructions and the command including model (`hc --skill § Delegate a task`). The posture tool lists already exist (`ask-in-herdr/SKILL.md:39-43`). **Untested**: how a template body and the task are joined, and whether a template can read `$HC_TERMINAL_ID` of the caller; verify on the first template. |
| Placement (`--tab`, `--direction`, `--label`) | Drop from the launch path. Add one sentence to the skill. | `hc run --bg` for background children (they appear under the parent as `sub_agents`); `herdr-app do tab.new --name … --argv … --task …` only when the person should see the child. | `herdr-app --skill` ("New spaces and tabs are shown immediately: only create them when asked"). The narrow-pane OpenCode hang that forced tabs (`GLOSSARY.md:25`) does not apply to a terminal that has no pane. **Untested**: whether `tab.new` sets `parent` on the new terminal. |
| Watcher, generations, receipts, TTL labels | Drop. | None. Use `hc wait --children any|all` while the turn is open, and rely on core notes after it ends. | The watcher existed because the TUI had no core-side notification (`child-initiated-callback…md` § Context: "herdr 0.8.0's `agent` CLI group has no subscribe verb"). hc types the note itself. ADR-0019 already rejected a durable supervisor. Duplicate suppression by generation protected against a watcher re-delivering; the core delivers each event once as far as the manual says (**untested** under core restart). |
| Continuation (`prompt --wait|--detach`) | Drop the wrapper. | `hc send`, `hc send --wait`, `hc send --if idle`. | Direct mapping. The baseline-seq dance guarded against stale `idle`; hc's `turn` counter and `--wait` tied to the caller's send (`hc schema` `terminal.send.caller`) cover it. |
| Reap guard | Thin helper or two lines in the skill. | Either a 20-line `hc-reap <t>` in `home/dot_local/bin` that refuses when `hc get <t>` shows `status: working|blocked` and otherwise runs `hc kill; hc rm`, or the same rule as prose. | The guard is the one piece of reap logic that is not in hc. Everything else (pair verification, tab ownership) addressed TUI panes that no longer exist. Prefer prose first; add the script only if a round shows agents killing working children. |
| Decision-brief hand-off | Keep as prose in the contract and in the template body. | Child duty: "Need a decision? Write a decision brief (`~/.claude/shared/decision-brief.md`) and `hc send <parent> …`; do not open a question dialog; end the turn." Parent duty: "A `blocked` note means the child opened a dialog anyway: `hc read` it, then either answer with `hc send --force` only for a question (never a permission), or ask the user." | hc's `blocked` model assumes a person. The repository's measured stall causes were interactive asks (`child-initiated-callback…md` symptoms), so the "no dialogs" instruction stays. |
| Resource tree, parent edge store, PATH wrapper, context hook | Drop. | None. `Terminal.parent`, `hc ls`, `hc events --children-of`, `herdr-app ls`. | The core records the only edge the tree reliably recorded (agent → agent). Pane/tab creator attribution cannot be recovered without intercepting `herdr-app`, and #594 says the app already nests children. ADR-0017 is superseded by a native parent field, which was its own first considered option ("Wait for a native Herdr provenance API"). |
| `herdr-peer list` | Drop. | `hc ls` (shows `agent`, `status`, `where`). | Observed output in trial A1. |
| Alias allocator (`herdr-peer-alias`) | Drop. | Callers (`se-*` peers) pass `--name <task>`. | `executable_herdr-peer-alias:3-4` names the `se-*` review peers as its only consumer; check `rg herdr-peer-alias home/` at implementation time. |

## 3. Migration order and follow-up issues

Dependencies run top to bottom. Each issue removes something; nothing is removed before its replacement exists.

### Issue A: Rewrite the child and peer contracts for hc

Scope: replace `home/private_dot_claude/shared/child-agent-contract.md` and `peer-message-contract.md` with one `agent-messaging-contract.md` (or two short files) built on `hc --skill`: addresses, `<hc from>` tags, end-the-turn rule, decision brief, reap guard, "no dialogs" child duty, parent duties on `blocked|error|exited` notes. Update `home/private_dot_claude/CLAUDE.md:84` to point at it.
Removes: the `[peer-message v1]`, `[child-ask vN]`, `[child-supervision v1]`, `[parent-reply vN]`, `[child-settled v1]` marker shapes and the 2026-08 TUI measurements (`child-agent-contract.md:15-184`).
Depends on: nothing. Blocks: B, C, D, E.

### Issue B: herdr-core templates and config under chezmoi

Scope: add `home/private_dot_config/herdr-core/templates/*.md` for the roles `tdd/dispatch.md:21`, `ask-in-herdr` and `code-review` use today (claude ro/rw, opencode rw, pi), each with the child-duties body from issue A; add `home/private_dot_config/herdr-core/config.toml` only if a setting is needed (`notes` stays default). Verify `first_message.sent` and the body/task join on each template once.
Removes: posture, model, effort, skills and agent handling in `herdr-child-launch.sh` (929 lines) once C lands.
Depends on: A. Blocks: C, D.

### Issue C: Retire `herdr-child`, `herdr-peer`, `herdr-peer-alias` and their libraries

Scope: delete `home/dot_local/bin/executable_herdr-child`, `executable_herdr-peer`, `executable_herdr-peer-alias`, `home/dot_local/lib/herdr-child-{runtime,supervision,watcher,launch,continuation,reap}.sh` (3244 lines); keep `herdr-process.sh` while `herdr-pane-labels` depends on it (`herdr-process.sh:4-6`, README "API 1"). Add `hc-reap` only if the prose rule fails. Name the deployed paths and `rm` commands in the PR body (CLAUDE.md "retiring a managed file").
Removes: tests `tests/bashunit/herdr_child_descriptor_probe_test.sh`, `smoke_test.sh:54-142,585-690`, `scripts_test.sh:16-89,2230-2850`; `~/.cache/herdr-child`.
Depends on: A, B. Blocks: D, E, H.

### Issue D: Rebuild `ask-in-herdr` on `hc run` / `hc wait`

Scope: `ask.sh` becomes `hc run --bg --name <n> --cwd <dir> <template> "<question> [report-transport]"`, `hc wait <n>`, read the report file, `hc kill; hc rm` or leave open with the printed address; `follow-up.sh` becomes `hc send [--wait]`. Keep the outcome contract (`ask-in-herdr/SKILL.md:56-69`) and the report-file transport. Rename the skill only if the owner wants (`ask-in-herdr` still describes the app).
Removes: `scripts_test.sh:2230-2810` stubs of `herdr`/`herdr-child`; the `[child-settled v1]` reminder prompt (`ask.sh:236-245`).
Depends on: B, C.

### Issue E: Skills and dispatch text

Scope: shrink `home/private_dot_agents/skills/herdr/SKILL.md` and `references/*.md` to a pointer: "read `hc --skill`; read `herdr-app --skill` to change what the person sees; the contract is at …". Rewrite the herdr mode in `tdd/dispatch.md:21-36`, `pf-build/SKILL.md:112,117`, `pf-issue/references/platform.md:31`; replace `HERDR_ENV=1` checks with `[ -n "$HC_TERMINAL_ID" ]`. Decide whether skill descriptions keep "herdr" (the app) or say "hc".
Removes: `references/agents.md`, `pane-io.md`, `layout-and-notifications.md`, `plugin-development.md` (TUI plugin API).
Depends on: A, C, D.

### Issue F: Retire the resource tree, the PATH wrapper and the context hooks

Scope: delete `home/dot_local/bin/executable_herdr` (wrapper), `executable_herdr-resource-tree`, `home/dot_local/lib/herdr-resource-tree.py`, `home/private_dot_claude/hooks/executable_herdr-resource-context.sh`, the Pi and OpenCode `herdr-resource-context.ts` plugins, the `SessionStart|UserPromptSubmit|PostToolBatch` entries in `home/private_dot_claude/private_settings.json.tmpl:84-138`, `docs/herdr-resource-tree.md`, `tests/bashunit/herdr_resource_tree_test.sh`. Supersede ADR-0017 with the ADR in issue H. Remove GLOSSARY entries "Resource creator", "Resource tree", "Agent resource context" or rewrite "Parent agent" to the `Terminal.parent` definition.
Removes: `~/.cache/herdr-resource-context`, the SQLite registry, PATH ordering that puts `~/.local/bin/herdr` first.
Depends on: #594 (the sidebar reads `herdr-resource-tree`, `home/private_dot_config/herdr/config.toml:157-158`) if the TUI sidebar must keep working until then; otherwise independent.

### Issue G: `herdr-run` on hc

Scope: replace the `HERDR_ENV=1` branch (`executable_herdr-run:127-130,178,398-418`: `tab create`, `pane run`, `pane get`) with `hc run --bg --name <label> --cwd <dir> -- <command>`, `hc wait <label>`, `hc read`. Keep the label, state directory and `verdict` subcommand. Update `CLAUDE.md:47,71` and `Makefile:44`.
Removes: `tests/bashunit/herdr_run_test.sh` fakes of `herdr tab create`/`pane run`.
Depends on: nothing.

### Issue H: Docs, glossary and ADR

Scope: ADR-0025 "Use herdr-core as the agent communication substrate", status accepted, supersedes 0024 and 0017, notes 0019 stays rejected; rewrite `GLOSSARY.md § herdr` (Child-agent contract, Peer address, Peer message, Parent agent); add a status note to `docs/show-me-herdr-supervision.md` and to `docs/solutions/architecture-patterns/child-initiated-callback-over-in-turn-supervision.md` (principle kept, mechanism now the core's notes); update `docs/herdr-worktrees.md:92-95` where the Claude `WorktreeCreate` hook finds `seigi.worktree-setup` through `herdr plugin list --json`.
Depends on: C, F.

### Issue I: `herdr-worktree-identity` without the TUI

Scope: the engine calls `herdr pane get`, `herdr api snapshot`, `herdr workspace get|rename` (`executable_herdr-worktree-identity:365-369,556,598,619`) and is gated by `HERDR_ENV` and `HERDR_PANE_ID` in all three adapters. Decide whether the app owns worktree naming now (#592 mentions a ⌘⇧N worktree key) and whether `herdr-app` exposes a space rename; then port or retire the engine, `home/dot_local/lib/herdr-worktree-state.sh`, the three adapters and `home/dot_local/lib/agent-hooks/worktree-identity.ts`. ADR-0008 and ADR-0018 (worktree setup) are affected.
Depends on: an owner decision (open question 4). Independent of A–H.

### Issue J: Retire the `herdr` TUI server and its plugins

Scope: see section 4. Remove `home/private_Library/LaunchAgents/com.seigiard.herdr-server.plist.tmpl`, `brew "herdr"` (`Brewfile.tmpl:78`), the `.zshrc` blocks at `home/dot_zshrc.tmpl:135-195` (`_herdr_report_machine`, image forcing, `herdr-restart`), the `lookPath "herdr"` hook block in `private_settings.json.tmpl:100-110`, `home/private_dot_config/herdr/config.toml`, the Ghostty startup command that runs `herdr`, and `herdr integration` hooks (`~/.claude/hooks/herdr-agent-state.sh`). Each plugin needs an app-side answer first (section 4).
Depends on: F, G, I, #594, #592.

## 4. What the old TUI still runs today, and when it can go

Observed on 2026-11-03 (`pgrep -fl herdr`, `ps -o pid,ppid,lstart,command`, `launchctl list | grep -i herdr`):

| Process | PID | Since | Started by | Role |
|---|---|---|---|---|
| `/opt/homebrew/bin/herdr server` (herdr 0.9.5) | 955 | 2026-10-28 06:18 | launchd `com.seigiard.herdr-server` (plist managed from `home/private_Library/LaunchAgents/com.seigiard.herdr-server.plist.tmpl`; `RunAtLoad`, no `KeepAlive`) | The TUI server. Every `herdr agent|pane|tab|workspace|api` call in this repository talks to it. |
| `herdr-pane-labels --sweep-daemon` | 1194 | 2026-10-28 06:18 | plugin `seigi.pane-labels` | Color-animal aliases, tab/pane labels, `$headline`/`$agent_line` sidebar tokens; depends on `~/.local/lib/herdr-process.sh` API 1. |
| `jmarbutt.spaces-pr-status … daemon.js` | 2600 | 2026-10-28 | plugin | PR status in the TUI sidebar (`home/private_dot_config/herdr/config.toml:107`). |
| `wakeup-herdr` | 25083 | — | plugin `herdr-wakeup` (ADR-0016) | Wake-up notifications for the TUI. |
| `herdr` (TUI client) | 37421 | 2026-10-29 18:18 | Ghostty window: `/usr/bin/login … zsh -lc '… if command -v herdr …; then herdr; fi …'` (PID 37410, parent Ghostty 37409) | A person's TUI session. Ghostty's startup command launches the TUI on every new window. |
| `herdr-core connect` | 9041 | 2026-11-03 08:11 | Herdr app (PID 9032, launchd `application.dev.herdr.app…`) | The app's link to the core. |
| herdr-core 0.1.17 | 9045 | uptime 21001 s at check | one-shot launchd job (`hc --skill § Status, recovery, and cleanup`) | `hc server status`: `live: 1, finished: 7` before the trials. |

Enabled plugin configs (`ls ~/.config/herdr/plugins/config`): `herdr-agent-metrics`, `herdr-auto-update`, `herdr-focus-notify`, `herdr-theme-picker`, `herdr-wakeup`, `jmarbutt.spaces-pr-status`, `keepawake.caffeinate`, `seigi.command-palette`, `seigi.focus-notify`, `seigi.pane-labels`, `seigi.worktree-setup`, `test.palette-probe`. Installed checkouts: `herdr-auto-update`, `herdr-wakeup`, `jmarbutt.spaces-pr-status`, `seigi.command-palette`, `seigi.pane-labels`, `seigi.worktree-setup`.

What the server still does for this repository:

1. Serves the TUI sidebar `[ui.sidebar.agents]`, which reads `herdr-resource-tree` and `herdr-pane-labels` tokens (`home/private_dot_config/herdr/config.toml:150-175`). Replacement: #594.
2. Hosts `seigi.worktree-setup`, which the Claude `WorktreeCreate` hook locates via `herdr plugin list --json` (`docs/herdr-worktrees.md:92-95`) and which writes the `herdr-generated-worktree` marker (`docs/herdr-worktrees.md:25-29`, ADR-0008). Replacement: unknown; issue I.
3. Hosts `seigi.pane-labels`, the alias allocator for `herdr-child` and `herdr-peer-alias`. Replacement: `--name` (section 2) and #594 for display.
4. Answers `herdr-run`'s tab mode (`executable_herdr-run:398-418`). Replacement: issue G.
5. Receives `herdr-worktree-identity` RPCs (issue I).
6. Is the thing the Ghostty startup command opens.

Retirement condition: issues F, G, I and J are done; #594 covers the sidebar; a decision exists for `seigi.worktree-setup`, `command-palette`, `focus-notify`, `wakeup`, `spaces-pr-status` and `keepawake.caffeinate` (keep as app mods, replace, or drop); the Ghostty startup command no longer runs `herdr`; no process except the server itself appears in `pgrep -fl herdr` for a week. Then: `launchctl bootout gui/$(id -u)/com.seigiard.herdr-server`, remove the plist, `brew uninstall herdr`, remove `~/.config/herdr` (`herdr.sock`, `herdr.sock.agent`, `plugins/`, logs). Until then the two systems coexist without conflict: the TUI does not see hc terminals, and hc does not see TUI panes.

## 5. Open questions for the owner

1. **Message kinds.** Drop `send|ask|reply` entirely (section 2) or keep `ask` as a one-word prefix convention in the body? The research recommends dropping.
2. **Child names.** Task names (`review`, `fix-auth`) as the manual suggests, or color-animal names generated by a small wrapper so the app's sidebar (#594) and the terminal name agree? Names are unique only among live terminals.
3. **Blocked children.** When a child opens a question dialog despite the instruction, may the parent answer it with `hc send --force`, or must it always go to the user? The manual forbids `--force` only for permission decisions.
4. **Worktree identity.** Does the Herdr app now own worktree creation and space naming (#592 lists a ⌘⇧N worktree key)? If yes, `herdr-worktree-identity` and `seigi.worktree-setup` need an app-side home or retirement (issue I). If no, the TUI server must stay for them.
5. **Visibility of children.** `hc run --bg` children are nested under the parent and have no tab (observed). Is that the default, with `herdr-app do tab.new` only when the person asks to watch? The old default was a visible tab.
6. **`notes` setting.** Keep the default (notes and `<hc>` tags on)? The research sees no reason to turn it off; every disposition in section 2 depends on it.
7. **Skill naming.** Keep the skill names `herdr` and `ask-in-herdr` (the app is still Herdr) or rename to `hc`/`ask-in-hc`?
8. **The Ghostty TUI session.** Is the TUI still used by hand (PID 37421 has been open since 2026-10-29)? If not, the Ghostty startup command is the first thing to remove in issue J.

## Appendix A: trial log (2026-11-03, from terminal t1, cwd /tmp)

All terminals were named `probe596*`, started with `sh` or `cat`, and removed before the end. No text was sent to any other terminal. `hc read t1 --lines 0` was the only read of a terminal not created here.

```text
A1  hc run --bg --name probe596 --cwd /tmp sh -c "echo PROBE_START; sleep 30; echo PROBE_END"
    → {"address":"t8","agent":"sh","cwd":"/tmp","name":"probe596","parent":"t1","state":"live","turn":0}   rc=0
    hc get probe596
    → {... "die_with_parent":true, "labels":{}, "notify":true, "parent":"t1", "reported":false, "status":null, "template":null ...}
    hc label probe596 role=probe owner=t596
    → {... "labels":{"owner":"t596","role":"probe"} ...}   rc=0
    hc read probe596 --lines 20
    → PROBE_START   rc=0
    hc wait probe596 --output PROBE_END --timeout 60
    → {"children":[],"ended":true,"exit_code":null,"reason":"output","signal":null,"status":null,"terminal":"t8","turn":0}
      (29.9 s wall clock)   rc=0
    hc get t1
    → {"address":"t1","name":null,"parent":null,"labels":{"herdr.seen":"72","herdr.space":"sp88be…","herdr.tab":"tbd8e1…","where":"my-mac-setup / olive-dogo"},
       "status":{"app":"claude-code","msg":"…","state":"working"},"title":"Herdr config migration","identity":"ghostty","notify":true}
    hc ls --all
    → t1 live working claude-code; t2–t7 finished zsh reason killed; t8 probe596 parent t1 finished reason exited
    hc exec env | grep -i herdr
    → __CFBundleIdentifier=dev.herdr.app
    env | grep -E '^(HC_|HERDR)'   (inside t1)
    → HC_SCOPE=…  HC_TERMINAL_ID=t1  HC_TERMINAL_SOCKET=/Users/seigiard/.local/state/herdr-core/default/default.sock
    herdr-app ls
    → space "my-mac-setup" → tab "olive-dogo" → terminal t1 (claude-code, name null, sub_agents ["t10","t9"])
A2  hc read t1 --lines 0 | grep -i 'hc\]\|<hc\|probe596'
    → "⏺ Это автоматическая заметка от herdr-core, а не ваше сообщение: пробный терминал t8 probe596 завершился с кодом 0."
      (the orchestrator's own reply to the exit note; the raw note text was not captured)
    hc rm probe596 → {"removed":"t8"}   rc=0
A3  hc run --bg --no-notify --name probe596-cat --cwd /tmp cat
    → {"address":"t9",…,"parent":"t1"}
    hc send probe596-cat "hello from t1 trial"
    → {"started":null,"status":null,"turn":0}   rc=0
A4  hc send --wait --timeout 5 probe596-cat "second line"
    → {"started":null,"status":null,"turn":0,"wait":{"children":[],"ended":false,"exit_code":null,"reason":"timeout",…,"terminal":"t9"}}   rc=0
    hc read probe596-cat --lines 10
    → hello from t1 trial / hello from t1 trial / second line / second line   (echo + cat output)
A5  hc send --if idle probe596-cat "x"
    → {"error":{"hint":"nothing was typed","kind":"status_mismatch","message":"t9 is silent, not idle"}}   rc=10
    hc wait --children all --timeout 5
    → {"children":[{"terminal":"t9","ended":false,"reason":"running",…}],"ended":false,"reason":"timeout","terminal":"t1"}   rc=0
    hc wait --children any --timeout 5
    → same shape, reason "timeout"   rc=0
A6  hc run --bg --no-notify --name probe596-short --cwd /tmp sh -c "sleep 3; exit 7"
    → {"address":"t10",…,"parent":"t1"}
    hc wait --children any --timeout 20
    → {"children":[{"terminal":"t10","ended":true,"exit_code":7,"reason":"exit",…}],"ended":true,"reason":"children","terminal":"t1"}
      (3.0 s wall clock)   rc=0
    hc get probe596-short → state finished, exit_code 7, reason "exited", parent t1
    hc wait probe596-short → {"ended":true,"exit_code":7,"reason":"exit","terminal":"t10"}   rc=0
A7  hc kill probe596-cat
    → {... "finished_ms":…,"labels":{"where":"my-mac-setup / olive-dogo"},"notify":false,"reason":"killed","signal":1,"state":"finished" ...}   rc=0
    hc rm probe596-cat → {"removed":"t9"}   rc=0
    hc rm probe596-short → {"removed":"t10"}   rc=0
    hc rm probe596-short → {"error":{"hint":"see `hc ls --all`","kind":"not_found","message":"no terminal \"probe596-short\""}}   rc=3
    hc send probe596-cat "x" → not_found   rc=3
    hc ls --all | names starting with probe596 → []
```

Untested in this research: `hc send` to a live agent terminal and the exact `<hc from>` tag; queueing of a send into a `working` agent; `blocked`/`error` note text; `hc rm` on a live terminal; templates (`hc run <template> "<task>"`, body/task join, `first_message.sent`); `hc put`, `hc interrupt`, `hc keys`; whether `herdr-app do tab.new` sets `parent`; note delivery across a core restart.
