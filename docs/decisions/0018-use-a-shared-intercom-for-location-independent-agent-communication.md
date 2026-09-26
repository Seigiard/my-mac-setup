---
title: Use a shared intercom for location-independent agent communication
status: accepted
date: 2026-09-12
supersedes: []
---

# ADR-0018: Use a shared intercom for location-independent agent communication

## Context

The child-agent contract currently carries decisions through `herdr-child
ask/reply`, coupling communication to Herdr placement and launch relationships.
That works for directly supervised panes but is not a shared agent-to-agent
communication model. The same agent may instead run under `nono` or inside a
container, and moving it should not change how another agent sends a message or
asks a question.

Agent Intercom already provides a broker, addressed messaging, blocking
ask/reply, and adapters for Claude Code, OpenCode, Codex, and Pi. Its adapters
and placement paths do not all have identical wake, acknowledgement, restart,
or remote-routing behavior. The project needs observed behavior before deciding
which additional semantics are requirements.

The project separately tracks sandbox permission mode and filesystem isolation
in [GitHub issue #215][permission-mode] and [GitHub issue
#216][filesystem-sandbox]. Those boundaries influence transport exposure and
model-network egress but do not define the communication API.

## Considered options

- Keep direct `herdr-child ask/reply` and implement a separate communication
  path for each new placement.
- Build and operate a project-specific broker and protocol.
- Evaluate Agent Intercom as the shared substrate, adding only placement bridges
  and focused policy or adapter changes demonstrated by real probes.
- Defer communication until durability, hierarchy authorization, and all harness
  semantics can be standardized together.

## Decision

Evaluate the Agent Intercom family as the shared substrate for agent-to-agent
communication. The first priority is connectivity, not hierarchy enforcement:
an agent must be able to send, ask, and reply to another named agent when either
endpoint runs directly on the host, under `nono`, or inside a container. The
agent-facing operation must not change with placement.

For the first MVP, location independence stops at one physical host and the
containers running on it. Local VMs, arbitrary remote machines, and federated
brokers are deferred. This keeps one logical local communication fabric while
allowing each placement profile to expose or bridge it differently.

Herdr aliases provide one consistent user-facing name across placements. The
initial MVP may retain Agent Intercom's relationship-scoped remote routing.
Allowing an exact alias to bypass that routing policy is recorded but deferred;
it is not a gate on proving useful communication between currently permitted
peers.

The explicit name is the globally unique alias from Herdr's pane-labels pool
that identifies an agent's pane. Herdr assigns it when it launches an agent
itself; where a pane has no agent record at all, the launcher allocates from the
same pool and registers the record before starting the client, so the pool
remains the single source of these names. The same alias is passed through every
placement launcher and registered with Agent Intercom. Agent Intercom session IDs and reconnect credentials remain
internal transport details rather than a second user-facing naming system.

The MVP does not require broker-owned persistence before sender success, typed
parent/child control messages, or a complete restart-safe acknowledgement state
machine. Agent Intercom's sender outbox and stable message IDs are sufficient to
evaluate useful communication. A thin trusted wrapper may own launch-time
enrollment, transport exposure, controlled network egress, name handling, and
recipient deduplication; it must not grow into a separate broker or protocol.

The first probe used the unmodified `dataforxyz/agent-intercom-claude` 0.11.0
broker at commit `7de76e5d4f6461b007b19dfc5dbcf11928868adc`. A remote child under
`nono` completed enrollment, ownership-filtered discovery, ask/reply, and sender
outbox replay across a broker crash. Replay retained one message ID while using
a new delivery ID. A message held only in broker memory disappeared across the
same crash, which is acceptable for the MVP when normal senders retain their
outbox. Recipient deduplication remains worth evaluating because the replay was
observed twice.

The `nono` probe is one communication profile, not the center of the design. On
macOS, filesystem denial alone did not prevent connection to the broker's local
Unix socket. `nono --block-net` plus an explicit remote-socket grant closed that
bypass, but that stricter network boundary is optional hardening rather than an
MVP requirement. A later real-harness probe ran named Pi under `nono` with normal
model network access and an explicitly allowed local Intercom runtime/socket.
Pi asked host OpenCode and received the correlated reply without a remote gateway
or adapter change.

A second probe ran the real Intercom client inside Docker Desktop. A private
container Unix socket proxied to a host TCP relay, which terminated at the
broker's authenticated remote gateway. Container-to-host send and
host-to-container blocking ask/reply both completed without a broker protocol
change.

Real container-harness probes then ran unmodified OpenCode 1.18.30 and Pi 0.85.1
adapters inside Docker Desktop. Both consumed enrollment credentials, registered
with broker-owned remote provenance, asked host OpenCode, received the correlated
reply `42`, and exited successfully along with the host receiver. Normal adapter
startup checks for a local broker endpoint, so the trusted container socket
facade translates only `health_ok.endpoint` from `remote` to `local`. Registration
and message traffic continue through the authenticated remote gateway. This is a
placement-launcher concern, not an adapter or broker protocol change.

Current candidate behavior is the baseline for deciding later semantics. Pi and
OpenCode persist inbound messages before acknowledgement and wake idle sessions;
Claude and Codex expose different plain-MCP, live, and headless-worker behavior.
No adapter stores messages for a recipient that is fully offline. Do not turn
these differences into new requirements until real communication flows show
which ones matter.

Restart and offline behavior was then observed on the deployed slice on
2026-09-23, with Claude Code 2.1.267, OpenCode 1.18.30, and Pi 0.86.1 launched
through `herdr-agent-intercom` in Herdr panes on one host. Five results matter
for later lifecycle semantics.

An unknown recipient fails fast rather than consuming the blocking window. Both
the Claude and Pi adapters returned `Message to "<name>" was not delivered:
Session not found` within a second of the call. Claude returned it as an error
result; nothing queued.

A recipient adapter that dies mid-ask is invisible to a Claude sender. Claude
issued a blocking ask to a busy OpenCode session and the OpenCode process was
terminated 9.8 seconds later. The sender received no disconnect signal, blocked
the full 45-second default window, and returned `No reply from
"opencode-98292-a6748612" within 45 seconds`. The message names the resolved
session ID rather than the name the caller addressed, so a dead peer and a slow
peer are indistinguishable from the sender's side.

The Pi adapter reports the same situation differently, though not by detecting
the disconnect. Pi asked the same busy OpenCode session, the receiver was
terminated 8.6 seconds in, and Pi returned a success result after its
30-second window: `Ask delivered to i295-rx, but no reply arrived within 30
seconds. Continuing without waiting; the connection closed before asynchronous
deferral could be confirmed.` The closing clause reports that Pi's own
`deferAsk` control call to the broker went unconfirmed; it carries no
information about the recipient. That probe terminated the receiver's whole
process group rather than a single process, so the broker may have died with
it, which would explain the failed control call and leaves the observation
confounded. What the run does establish is the result shape: Pi returns success
and keeps the ask open where Claude and OpenCode return an error. No adapter
was observed telling a blocked sender that its recipient had disconnected.

An in-flight ask does not survive either endpoint restarting, and the two ends
fail asymmetrically. After the recipient restarted in the same pane under the
same launch name, its `intercom_pending` reported no unread messages and the
dead session left no entry in `intercom_list`; addressing the restarted peer by
name succeeded immediately with a correlated reply, while its previous session
ID returned `Session not found`. After the *sender* was terminated mid-ask and
restarted under the same name, the receiver had already queued the message, and
its `intercom_reply` failed with `Message to
"claude-my-mac-setup-main-02dbc5e7-60244" was not delivered: Session not
found`. Replies route to the original sender's session ID, which no restart
preserves, so the ask remains unresolvable in the receiver's pending list while
the restarted sender sees an empty `intercom_pending`. Unresolved asks
accumulate there: a later unselected `intercom_reply` failed with `Multiple
pending asks — specify to using a sender from intercom_pending`. The name is
the durable address; a session ID is per-process and must not be cached.

Registration is not readiness. One Pi session appeared in every other session's
`intercom_list` while reporting that its intercom tools were unavailable, after
Pi announced `Pi extensions updated. Restart Pi to use them.` A peer listed as
present may still be unable to answer. Pi's `intercom_list` also includes the
calling session, which Claude's excludes by default.

A real cross-harness probe used Claude Code 2.1.236 as the sender and OpenCode
1.18.30 with the current OpenCode adapter as the receiver. Claude issued a
blocking ask while OpenCode was busy in a 60-second tool call. OpenCode accepted
the injected turn afterward, called `intercom_reply`, and Claude received the
correlated reply. Both harness processes exited successfully.

A second cross-harness probe used Pi 0.85.1 with the current Pi adapter as the
sender and the same OpenCode adapter behavior as the receiver. Pi's blocking ask
and OpenCode's correlated reply completed successfully. Pi exposed a generated
`subagent-chat-...` fallback alias when launched without `--name`, so a launcher
that wants the Herdr alias as the visible name must pass Pi's normal session-name
option.

The real harness matrix also passed in both selected permissive `nono`
placements. Host Claude sent a blocking ask to OpenCode running under `nono`;
OpenCode received the injected turn and returned the correlated reply `42`.
Claude running under `nono` then sent one blocking ask to host OpenCode and
received the correlated reply `42`. Both processes exited successfully in each
probe. Neither path required the authenticated remote gateway, a broker change,
or an adapter change.

Real Codex CLI 0.154.0 also used the unmodified Codex adapter 0.10.0 at commit
`ff1f0e2258ded8c81ae6fcf33048c78a7f8580fe` to ask host OpenCode from both the
host and the stock `nolabs-ai/codex` confinement profile. Each path issued one
blocking plain-MCP ask, received the correlated reply `42`, and exited
successfully along with the receiver. This establishes the plain-MCP outgoing
flow; it does not establish wake behavior for a persistent `coi` worker.

The permissive OpenCode profile keeps its XDG state inside an allowed sandbox
runtime and exposes existing OpenCode auth files read-only. The Claude profile
uses the stock `nolabs-ai/claude` profile plus the allowed Intercom runtime. On
macOS, the logged-in Claude session is stored in Keychain, so the launcher reads
the existing OAuth access token before entering the sandbox and passes it only
through the child environment. These are launcher concerns, not changes to the
agent-facing communication operations.

Remote-tree policy filters both discovery and delivery, so even an exact
unrelated name is reported as absent. The policy is compiled into Agent Intercom
Core and has no runtime configuration. Unrestricted exact-alias routing is
deferred; if it becomes necessary, it will require a focused upstream or
maintained-fork policy change because a launcher-only wrapper cannot override the
broker's denial.

Keep direct Herdr communication available until the selected Agent Intercom
adapters prove the required communication cases. Security hardening, strict
authority typing, richer lifecycle states, attachments, file reservations, and
task orchestration remain optional follow-up work rather than gates on basic
connectivity.

The first deployed host slice pins the tested Core, Claude, OpenCode, and Pi
commits in one package root under `~/.local/share/agent-intercom`. A Herdr-only
launcher derives the public name only from the current pane record and verifies
membership in the pane-labels package's alias pool. Managed callers select a
free pool alias before `herdr agent start`; the pending pane record already
exposes that name, and later reconciliation retains it. `HERDR_CHILD_LAUNCH=1`
marks managed child-launch context, not an Intercom address. The legacy
`HERDR_CHILD_NAME` migration fallback and explicit context required for direct
upstream launches are documented in the child-agent contract. A provisional name or an
unavailable allocator produces a warning and starts the client without Intercom.
The launcher never waits for reconciliation while blocking client startup: Herdr
forbids renaming a pending launch.

A missing record is different, and it is the ordinary plain-shell case. Herdr
builds a pane's agent record by detecting the started client from the terminal
title it emits, so the alias the launcher wants comes into being strictly after
the moment it is needed, and no amount of waiting reaches it. The launcher
therefore declares the record itself: `herdr pane report-agent` creates it and
`herdr agent rename` puts a pool alias on it, both before the client starts.
That rename is also the collision boundary, because `agent_name_taken` is
decided by the server rather than by a name chosen locally. A record that
already exists is never renamed; it belongs to whoever created it.

Declaring works once per pane, and the fallback below is why a relaunch still
enrolls. A pane that has hosted a Claude session keeps the `claude`
agent-session identity that client's `SessionStart` hook reported, and Herdr
exposes no way to clear, replace, or age it out: from then on the pane ignores
`pane report-agent` for that agent kind and reports success while creating
nothing, so the rename has no record to act on. The launcher tells that refusal
apart from a taken name — only `agent_name_taken` is worth another candidate —
and keeps the alias it allocated, enrolling under a name Herdr does not yet
know. It records the pending rename, and the first-prompt hook renames the
record Herdr's own detection created. This gives up the property the paragraph
above relies on: for that one case the collision boundary moves after the
client starts, and the Herdr alias and the Intercom name differ until the first
prompt. Accepted because the alternative is no Intercom at all on every
relaunch, the divergence is bounded and self-healing, and a name lost to a
collision meanwhile is reported rather than retried forever. A session that
cannot record its pending rename starts without Intercom instead, because a name
no peer can discover is worse than a warning.

Only Claude Code takes this path. Declaring the record claims the pane's
lifecycle authority, which suppresses Herdr's own screen detection until it is
released, and the only release surface this repository deploys is Claude Code's
first-prompt hook. OpenCode's and Pi's own transports gate tool calls rather
than lifecycle, so a claim taken for them could never be given back; they keep
the fallback until they have a release surface of their own. The launcher declares
`unknown` rather than a state it cannot observe, so the window is honest instead
of false, and `herdr-agent-intercom-release` ends it from the client's first
prompt, once detection can take over. Release is deferred that far because
against a pane with no detectable client it destroys the record and the alias
with it. A session that dies before its release leaves the pane reading
`unknown`: stale, and distinguishable from a healthy idle pane.

The launcher runs interactive Claude sessions through live MCP `cci`, exports OpenCode's
adapter name, and passes Pi's normal session name. Claude and Pi utility
launches and nested launches in the already-enrolled pane pass through unchanged.
A new child pane resolves its own alias even when it inherits its parent's
enrollment environment. The Claude bridge removes `cci`'s synthetic permission
selector;
the caller's native flag, or otherwise Claude's project and user settings,
continues to decide the permission mode. OpenCode does not classify subcommands
at the launcher boundary and loads only its server plugin. Codex is deferred
because its tested wakeable worker and proactive MCP surface register separate
Intercom identities.

The launcher owns the host runtime location through `INTERCOM_DIR`, defaulting to
`${XDG_STATE_HOME:-$HOME/.local/state}/agent-intercom` while honoring an explicit
override. The runtime contains durable credentials and message state as well as
sockets, so a temporary/cache directory is unsuitable. Keeping the upstream
Pi-relative default would couple all clients' state to Pi configuration resets;
a compatibility symlink would retain that path dependency. Use the upstream
runtime-only override instead of changing `PI_CODING_AGENT_DIR`, which also moves
Pi's own configuration.

Until the coordinated Pi, Claude, and OpenCode PRs land, pin their small fork
patches by exact commit; see the [runtime storage inventory](../agent-setup-inventory.md#runtime-storage)
for PR links and removal instructions. Core and the transport protocol remain
unchanged. The initial rollout starts fresh because the existing state belongs
only to manual testing; it does not migrate or delete that state. Upstream keeps
ownership of restrictive directory and credential file modes (`0700`/`0600`).

## Consequences

The implementation must prove each supported placement with real agents rather
than infer compatibility from the shared protocol. Host, confinement, and
container launchers may need different transport setup while sharing one
agent-facing communication model.

Delivery may repeat after reconnect. Consumers that perform side effects before
acknowledgement may need a small stable-message-ID deduplication layer. The MVP
may accept weaker guarantees when duplicate handling is not material to the
interaction being tested.
Implementation and verification are tracked in
[GitHub issue #253][mailbox-issue].

[permission-mode]: https://github.com/Seigiard/my-mac-setup/issues/215
[filesystem-sandbox]: https://github.com/Seigiard/my-mac-setup/issues/216
[mailbox-issue]: https://github.com/Seigiard/my-mac-setup/issues/253
