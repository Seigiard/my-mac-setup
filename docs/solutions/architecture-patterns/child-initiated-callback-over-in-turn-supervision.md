---
title: In-turn supervision of child agents is a dead end — callback in, stalls designed out
date: 2026-08-21
category: architecture-patterns
module: herdr
problem_type: architecture_pattern
component: development_workflow
severity: high
resolution_type: workflow_improvement
related_components:
  - tooling
applies_when:
  - "Designing supervision of child agents launched by a parent whose turn ends the moment it stops issuing tool calls"
  - "Choosing between parent-side wait/poll/subscribe and a child-initiated callback for cross-agent coordination"
  - "A child agent can stall on an interactive ask (permission dialog, question tool) with no human watching the pane"
  - "Deciding whether a measured stall cause is suppressed at launch time or granted in shared config"
  - "Publishing a waiting state whose publisher runs no loop and cannot refresh its own signal (TTL'd labels)"
symptoms:
  - "Any in-turn wait/poll/subscribe on a child dies silently when the parent's turn ends"
  - "A stalled child holds a worktree, a model session, and the user's attention with nothing in the sidebar or the parent's transcript saying so"
  - "Measured stalls all trace to two interactive asks: opencode external_directory permission asks (34 of 22,719 decisions) and question-tool asks (4 of 18,020 tool calls)"
tags:
  - herdr
  - child-agents
  - turn-lifecycle
  - child-initiated-callback
  - stall-prevention
  - launch-contract
  - permission-config-split
  - ttl-state-label
---

# In-turn supervision of child agents is a dead end — callback in, stalls designed out

## Context

A parent agent running in a herdr pane needed to start child agents in sibling panes and stay responsive to them. The repo had three supervision mechanisms — `herdr agent wait`, `herdr pane wait-output`, and the `herdr-pair` driver loop — and all three share one fatal property: they block inside the parent's turn. "A parent agent's turn ends when it stops issuing tool calls" — when the turn ends, the supervision ends with it, and "the child keeps running in a pane nobody is reading" (`docs/plans/2026-08-17-1630-feat-child-agent-launch-contract-plan.md:36`).

The failure was observed, not hypothesized: a parent started an opencode child, confirmed `working`, ended its turn; the child later asked which test lane to use and nothing ever brought the parent back (plan:38). herdr 0.8.0's `agent` CLI group has no subscribe verb, and while the socket API exposes `events.subscribe` / `events.wait` on `pane_agent_status_changed`, "a subscription lives only as long as the process holding the socket, so on its own it does not survive the parent's turn either" (plan:38). The precise form of the rule: supervision *from inside the parent's turn* is the dead end; an external subscriber process is the tracked backstop (`docs/issues/2026-08-17-001-herdr-event-subscription-supervisor.md`), deliberately not a substitute for the callback.

The child agent launch contract (feature commit a537ce8, merged to main via PR #13 merge commit 02f031e; follow-up hardening in d463123 "preserve blocked child outcomes" and d8368be "make child reaping fail closed" — all four reachable from main) resolved this with two coupled principles.

## Guidance

### Principle 1 — In-turn supervision of children is a dead end; invert control

Every waiting mechanism dies with the parent's turn. The survivable design makes the CHILD call back, and makes everything else passive state the parent pulls on demand:

- **The child initiates the return.** `herdr-child ask` submits a marked message into the parent's pane via `herdr agent prompt` (`home/dot_local/lib/herdr-child-continuation.sh`), "which starts a turn in the parent's session — the only path from a child back to a parent that does not depend on the parent still being inside its own turn" (plan:52, R16). The key decision explicitly rejects "any mechanism that wakes the parent without the child acting: every such mechanism needs a process that outlives the parent's turn" (plan:52).
- **`ask` itself never waits.** It returns as soon as delivery succeeds (KTD9, plan:272): "waiting inside the current turn would be the same trap this work exists to escape." The script prints "Question delivered. End this turn and wait for the parent reply." (`home/dot_local/lib/herdr-child-continuation.sh:324`) — the child's turn ends too; the reply starts a new one.
- **Passive state covers observation.** Before sending, `ask` publishes a sidebar state label `blocked=waiting for parent` with a 1-hour TTL (`home/dot_local/lib/herdr-child-continuation.sh`) — a waiting child runs no loop, so it cannot refresh a short-lived label; the parent clears it in the same step as the reply, and the TTL is the backstop for a parent that never returns.
- **The parent's coordination verbs are fire-and-return, with one bounded exception.** The dispatch table in `home/dot_local/bin/executable_herdr-child` carries seven subcommands — `start`, `ask`, `reply`, `reap`, plus `verify` (confirm an alias-and-pane pair), `prompt` (ordinary follow-up), and the internal `__watcher` — alongside help and an unknown-subcommand error. The four coordination verbs are launch, be called back, answer, and clean up settled panes on a later turn (`reap_children` in `home/dot_local/lib/herdr-child-reap.sh`, which fails closed — keeping panes that are focused, still working, carrying a waiting label, or whose state cannot be parsed). The exception: attached `prompt --wait` does wait inside the parent's turn, via `wait_for_fresh_settlement()` in `home/dot_local/lib/herdr-child-continuation.sh`. It is sanctioned because it is bounded by a baseline it owns — `child-agent-contract.md:191`: "`--wait` starts no watcher. It returns only after a lifecycle sequence newer than its own prompt baseline settles." That is the narrow case this pattern rules *in*; open-ended parent-side polling for a child that may never speak again is what it rules out.
- **Failure also ends in a stop, not a wait.** A failed `ask` exits non-zero and leaves the label published (`home/dot_local/lib/herdr-child-continuation.sh`); the child's duty is to "stop instead of guessing" (`home/private_dot_claude/shared/child-agent-contract.md:230`).

### Principle 2 — Design out the stalls instead of detecting them

The plan measured what actually stalls a child before deciding what to build. From `~/.local/share/opencode/log/opencode.log`: 34 of 22,719 permission decisions were `ask`, and **all 34** were `external_directory` reads outside the worktree; separately, opencode's `question` tool raised 4 asks out of 18,020 tool calls (plan:40). Both causes were then removed at launch time rather than monitored for at runtime:

- **Question dialogs are removed per-kind at launch.** claude children get `--disallowed-tools AskUserQuestion`; opencode children get `OPENCODE_PERMISSION` with `"question":"deny"` set as a pane environment variable; pi children get `--exclude-tools ask_user` in the native args (`home/dot_local/lib/herdr-child-launch.sh`; R13, plan:86). The child's initial prompt reinforces it: "Do not open an interactive question dialog" in the same module.
- **The external-directory permission ask is removed in shared config.** `home/private_dot_config/opencode/opencode.json.tmpl:6-10` replaces the old enumerated allowlist with `"permission": {"external_directory": {"*": "allow"}}` — the enumerated list had granted `~/.claude/skills/**` but not `~/.config/opencode/skills/*`, one of the measured ask paths (plan:239), so children kept stalling on exactly the paths nobody had added yet.
- **The split has a rationale, not just a location.** "Split permission enforcement between the config file and the launch environment. Open read access helps the user's own sessions too; a suppressed question tool would harm them... the question dialog is only harmful where nobody is watching the pane" (plan:46). What helps everyone goes in shared config; what would harm an interactive session lives only in the launch path.
- **Removing the stall does not remove the decision.** "Removing the child's question tool removes the stall, not the decision the child was stalling on" (plan:56) — so the launch prompt substitutes the escalation path: "If you need a question or blocking decision, run: herdr-child ask '<decision brief>'" (`home/dot_local/lib/herdr-child-launch.sh`; child duties in `child-agent-contract.md:223-231`).

## Why This Matters

Any orchestration where the orchestrator is itself an LLM with turn-based execution — not a daemon — has this exact shape. The orchestrator cannot poll, cannot hold a subscription, cannot sit in a wait loop: anything it "watches" is only watched until its turn ends. The two viable channels are:

1. **Event-driven inbound** — the worker injects an event that starts a new orchestrator turn (here: `herdr-child ask` prompting the parent's pane).
2. **State-based pull** — durable, self-describing state the orchestrator (or a human) reads on a later turn (here: TTL'd sidebar labels, `herdr agent list` status, reap-on-demand).

In-turn blocking is not a third option, no matter how the wait is spelled.

### Update: external per-child supervision is the backstop

The later detached-supervision work preserves this rule while closing the non-cooperative settlement gap. The rejected design was supervision performed by the parent inside its own turn. `herdr-child start --detach` now starts a separate per-child watcher process that survives that turn, closes inherited descriptors, binds terminal plus `agent_session` identity, and requires a lifecycle sequence newer than the prompt baseline.

The watcher sends generation-and-event markers for fresh settlement, native blockage, timeout, or unplanned child disappearance. Timeout wakes once without killing the child, then the watcher continues until later settlement. `herdr-child ask` remains the primary decision callback and records confirmed delivery so the watcher can suppress its known ordinary duplicate. `reply` and pair-addressed `prompt --detach` advance generation and rearm; attached `prompt --wait` waits for its own newer sequence. This is an external process backstop, not a return to parent-turn polling, a global daemon, or a claim that lifecycle state proves task success.

The second principle compounds this: a stall in an unwatched pane is silent — "a stalled child holds a worktree, a model session, and the user's attention budget, and nothing in the sidebar or the parent's transcript says so" (plan:42). Detection would require exactly the supervisor process the turn model forbids. Measuring the real stall causes (two, both enumerable) and deleting them at launch is strictly cheaper than building runtime detection for them — and the measurement kept the fix honest: only the two causes with data behind them were removed; claude's dialog removal is explicitly noted as preventive, since no claude stall was ever measured (plan:224).

## When to Apply

- Designing any parent/child or orchestrator/worker agent topology where the orchestrator is turn-based (an LLM session, a chat agent, a webhook-driven bot). Reject every design whose correctness depends on the orchestrator waiting.
- When a subprocess or child agent can raise an interactive prompt (permission ask, question tool, confirmation dialog) in a context nobody watches: enumerate those prompts from real logs, then suppress or pre-grant them at launch. Keep the split rule — a grant that also helps interactive sessions belongs in shared config; a suppression that would harm interactive sessions belongs only in the unattended launch path.
- When tempted to add polling, watchdogs, or stall detectors: first ask whether the stall cause can be removed at the source. Build detection only for what cannot be removed — and file that gap explicitly rather than pretending coverage (see the consciously accepted gaps below).
- Not applicable when the orchestrator genuinely is a long-lived process (a daemon, smithers, a CI runner) — those can hold subscriptions and poll. That is exactly the sibling case: se-pipeline's external review legs are non-interactive one-shot subprocesses supervised by a durable engine that outlives them (idle timeouts on output bytes, wall-clock caps, fail-closed report parsing — `docs/solutions/design-patterns/external-review-legs-as-unreliable-subprocesses.md`). That toolkit presumes a supervisor that survives; an LLM parent's turn does not, so the direction inverts.

## Examples

- **Callback mechanism**: `ask_parent()` in `home/dot_local/lib/herdr-child-continuation.sh` — publish waiting label, verify a live parent occupies the launch pane, inject `[child-ask v1 agent=<name> pane=<pane-id>]` + body, exit without waiting.
- **Reply-and-clear as one step**: `reply_child()` in `home/dot_local/lib/herdr-child-continuation.sh` — the label clear happens only after delivery succeeds; a failed delivery leaves the label standing as "the last visible sign that the child is still waiting" (plan:508).
- **Reap on demand, fail closed**: `reap_children()` in `home/dot_local/lib/herdr-child-reap.sh` — closes only panes whose agent reads `done`/`idle`, unfocused, no waiting label, re-checked against a fresh `herdr agent list` immediately before close (hardened in d8368be).
- **Launch-time suppression matrix**: posture and native-option-mapping tables at plan:340-364; implementation in `home/dot_local/lib/herdr-child-launch.sh`.
- **Measured end-to-end**: the full callback and reap flow is recorded with dates and commands in `home/private_dot_claude/shared/child-agent-contract.md:103-109`.

## Related

- `docs/plans/2026-08-17-1630-feat-child-agent-launch-contract-plan.md` — the full plan; Problem Frame at :34-42, Key Decisions at :44-59, KTDs at :264-275.
- `home/private_dot_claude/shared/child-agent-contract.md` — the contract as told to child agents: measured herdr facts, parent duties, child duties, marker shapes.
- Consciously accepted risks, filed as open issues rather than left implicit:
  - `docs/issues/2026-08-18-002-sandbox-a-child-agents-filesystem-access.md` — the `"*": "allow"` external-directory grant is machine-wide, covering the user's own sessions; the sandbox that will contain it is the named next piece of work (decision at plan:51).
  - `docs/issues/2026-08-18-001-launch-time-permission-mode-for-child-agents.md` — children inherit the shared permission mode (bypassPermissions); read-only withholds tools without enforcing a write boundary (decision at plan:55).
  - `docs/issues/2026-08-17-001-herdr-event-subscription-supervisor.md` — the per-child watcher now covers ordinary lifecycle wakes; this issue remains for crash/restart resilience and a global event subscriber.
  - `docs/issues/2026-08-18-021-harden-child-agent-ownership-and-launch-cleanup.md` — no ownership enforcement: any parent-side session can `reply`/`reap` any child; the callback markers and env are coordination data, not credentials.
  - `docs/issues/2026-08-18-003-headless-peer-consult-outside-herdr.md` — a capability the contract deleted (headless peer consult) with no replacement; tracked, not overlooked.
- `docs/solutions/design-patterns/external-review-legs-as-unreliable-subprocesses.md` — sibling pattern for the case a durable engine CAN supervise; its guidance 2 (pin the harness env at dispatch because prose is measurably insufficient) is the same design-out-the-stall move made there.
- `docs/solutions/design-patterns/absolute-paths-beat-prose-in-agent-isolation.md` — same family: structure beats prose in a dispatched agent's contract; here the structure is the launch command and env, and the callback instruction (R3) is the one prose-only remainder, stated as such.
- `2026-08-18-020` — done: the herdr-pair deletion's plan-reference fallout; herdr-pair is the named prior art whose whole state machine lived inside one driver turn — the shape this learning replaces.
- Merge state: a537ce8 (feature), 02f031e (PR #13 merge), d463123, d8368be — all verified reachable from main.
- Closed issues above are bare IDs, for archaeology in git history: `2026-08-18-020`.
  Those files were removed in the closed-issue cleanup; the evidence they carried is reproduced inline above.
