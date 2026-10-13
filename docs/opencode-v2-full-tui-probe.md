# OpenCode 2 Full-TUI Probe

This is an opt-in live probe for the OpenCode 2 full TUI. It does not change
the normal OpenCode 1 pin or any source-managed configuration.

The probe was last exercised on 2026-10-13 with OpenCode `2.0.28` from
`@opencode/cli` and Herdr `0.9.3`.

## Isolated Setup

Choose an empty probe root outside the checkout. `mktemp -d` gives this run a
unique owned root. The package and every client home below belong to the probe
and may be removed after it ends.

```sh
probe_root="$(mktemp -d "${TMPDIR:-/tmp}/opencode-v2-herdr-probe.XXXXXX")"
mkdir -p "$probe_root/package"
mkdir -p "$probe_root"/{home-a,home-b,home-control,home-pi}/.config/opencode
npm install --prefix "$probe_root/package" @opencode/cli@2.0.28 --no-audit --no-fund

for home in home-a home-b home-control; do
  env -i HOME="$probe_root/$home" PATH="$PATH" herdr integration install opencode
done
env -i HOME="$probe_root/home-pi" PATH="$PATH" herdr integration install pi
```

`herdr integration install opencode` owns the generated OpenCode files. A
successful install creates both `plugins/herdr-agent-state.js` and
`herdr-tui-session.js`, and adds the latter to `tui.jsonc`. Do not copy or
hand-edit either file. The server plugin alone is not the full-TUI integration.

The standalone V2 TUI can use bundled `opencode/cat-jam-free` without paid
credentials. The Pi peer uses `openrouter/cohere/north-mini-code:free`. Before
starting Pi, verify that its isolated environment has a runnable credential or
provider path without printing credentials:

```sh
HOME="$probe_root/home-pi" \
  pi auth check --model openrouter/cohere/north-mini-code:free --json
```

If that check needs credentials, configure them through the provider's normal
interactive flow or the invoking shell's secret environment. Do not put a key
in a command, config file, or this document. A Pi launch with
`openai-codex/gpt-5.5` and no key reached the real provider boundary and failed
with `No API key found for openai-codex`; use the free OpenRouter model only
when its readiness check succeeds.

Create four tabs and save each returned root pane ID. The first two are the
ordinary V2 peers, the third is the V2 negative control, and the fourth hosts
Pi.

```sh
herdr tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$PWD" \
  --env "HOME=$probe_root/home-a" --no-focus
herdr tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$PWD" \
  --env "HOME=$probe_root/home-b" --no-focus
herdr tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$PWD" \
  --env "HOME=$probe_root/home-control" --no-focus
herdr tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$PWD" \
  --env "HOME=$probe_root/home-pi" --no-focus
```

## Launch And Discover

Start the three V2 clients directly in their tabs. Do not call `herdr agent
start` for them and do not supply agent names: the full TUI reports to Herdr
and Herdr allocates their peer addresses.

```sh
opencode2="$probe_root/package/node_modules/.bin/opencode2"
for pane in <pane-a> <pane-b> <pane-control>; do
  herdr pane run "$pane" "env -i HOME=\"\$HOME\" PATH=\"\$PATH\" TERM=\"\$TERM\" \
    HERDR_ENV=\"\$HERDR_ENV\" HERDR_SOCKET_PATH=\"\$HERDR_SOCKET_PATH\" \
    HERDR_PANE_ID=\"\$HERDR_PANE_ID\" \"$opencode2\" --standalone"
done

herdr agent start pi-probe --kind pi --pane <pane-pi> -- \
  --model openrouter/cohere/north-mini-code:free
```

Use the visible V2 TUIs to submit a short initial prompt to each V2 client,
including the control. This bootstrap makes the control discoverable; keep it
passive afterward and never send an addressed peer message to or from it. Use
the visible Pi TUI for Pi's initial prompt. Then discover their current records
before sending any addressed peer message:

```sh
herdr agent list
herdr agent get <current-v2-a-address>
herdr agent get <current-v2-b-address>
herdr agent get <current-control-address>
herdr agent get <current-pi-address>
herdr agent explain <current-v2-a-address> --format json --verbose
```

Require distinct non-empty V2 names and distinct native `agent_session`
values. Record each address, pane, terminal, and native session. A process can
be detectable or have an alias before native session reporting is available, so
do not route a peer message until `agent get` reports the current native
session. The initial direct TUI prompt is bootstrap, not evidence that address
allocation always waits for a first native session.

Require `screen_detection_skip_reason: "full_lifecycle_hook_authority"` for a
V2 full-TUI record. Prove a busy state with a real action such as a shell
`sleep`, then read `herdr agent get <address>` while the action is still
running. A startup delay or the presence of a server plugin is not evidence of
the TUI lifecycle path.

For same-pane reuse, exit the V2 TUI, rerun its direct `--standalone` command
in the same pane, and submit its next bootstrap prompt in the visible TUI.
Run `herdr agent list` and `herdr agent get <current-address>` again before
peer routing. Record the old and current sessions, then send a unique marker to
the newly discovered address and verify it in the new conversation and not the
old one.

## Peer Matrix

Read `~/.claude/shared/peer-message-contract.md` before sending messages. Use
only V2 A, V2 B, and Pi for `herdr-peer ask` and `herdr-peer reply`; the V2
control is a passive negative control and must never send or receive an
addressed marker. From each of those three clients, verify the recipient
conversation contains its unique marker:

```text
[peer-message v1 from=<alias> pane=<pane-id> kind=send|ask|reply]
```

Exercise V2-to-V2 and V2-to-Pi idle delivery. Then give the recipient a real
`sleep 60`, confirm `herdr agent get` reports `working`, and submit an `ask`
from the sender. A successful `herdr-peer ask` proves submission to Herdr; the
later peer marker as a user message in the recipient conversation proves the
queued message was processed. After the busy action settles, send the matching
`reply` and verify it in the sender conversation. Check the passive V2 control
only for absence of addressed markers.

## Cleanup

Close only the tabs or panes returned by this probe's `herdr tab create` calls.
Remove only the probe root after preserving the evidence:

```sh
herdr pane close <pane-a>
herdr pane close <pane-b>
herdr pane close <pane-control>
herdr pane close <pane-pi>
rm -rf "$probe_root"
```

This procedure is not a version migration or a replacement alias allocator.

## Recorded Result

The original isolated probe ran on 2026-10-13 with OpenCode `2.0.28` from
`@opencode/cli` and Herdr `0.9.3`. Its ordinary V2 TUIs used bundled
`opencode/cat-jam-free`; its working Pi peer used
`openrouter/cohere/north-mini-code:free`.

### Original Idle Run

The original run established idle delivery. Its complete raw conversation
exports were not all retained; the identities, markers, and observed receipt
below are from `controls/live-v2-probe.md`.

| Client | Address | Pane | Terminal | Native session |
| --- | --- | --- | --- | --- |
| V2 A | `cyan-grouse` | `w70:p3` | `term_65db61a64d13831b` | `ses_ecb3b2fb9ffe7qUYflWWwjgzun` |
| V2 B | `khaki-grouse` | `w70:p4` | `term_65db61b961e5731c` | `ses_ecb3aa130ffeWvy208T1OvrzVo` |
| Pi peer | `coral-woodpecker` | `w70:p5` | `term_65db625e99f7a31e` | `2026-10-13T10-29-16-368Z_01a134cf-31cd-71b9-baae-c65bdf8f407d.jsonl` |
| Pi control before restart | `azure-ermine` | `w70:p5` | `term_65db625e99f7a31e` | `2026-10-13T10-19-37-089Z_01a134c6-5b00-7207-88d0-b41c08e12e43.jsonl` |

| Scenario | Sender and recipient | Observed marker and receipt | Result |
| --- | --- | --- | --- |
| Idle V2-to-V2 | `cyan-grouse` -> `khaki-grouse` -> `cyan-grouse` | `V2-A-ASK-IDLE-20261013T1020Z` reached `khaki-grouse`; `V2-B-REPLY-IDLE-20261013T1021Z` reached `cyan-grouse`. | Passed. |
| Idle V2-to-Pi | `cyan-grouse` -> `coral-woodpecker` -> `cyan-grouse` | `V2-A-TO-PI-ASK-20261013T1030Z` reached Pi; `PI-TO-V2-REPLY-20261013T1031Z` reached V2. | Passed. |
| Original negative control | `azure-ermine` | The Pi control did not receive either addressed V2-to-V2 marker before its restart. | Passed. |

The V2 lifecycle record for `cyan-grouse` reported
`full_lifecycle_hook_authority`. While it ran `sleep 15`, Herdr reported it as
`working` with its recorded native session.

### Follow-Up Busy Run

The later follow-up used fresh isolated homes and the same versions. Its raw
OpenCode exports and Pi JSONL remain in the investigation controls directory.
These identities are separate from the original idle run. Terminal IDs are
copied from the retained `controls/e2-*.json` observations; an ID not retained
in those snapshots is marked `not retained`.

| Client | Address | Pane | Terminal | Native session |
| --- | --- | --- | --- | --- |
| V2 sender | `lilac-rat` | `w70:p6` | `term_65db67d6dcc9c322` | `ses_ecb21d802ffe5fX2E3hHfhqAue` |
| V2 reused pane, old occupant | `silver-greyhound` | `w70:p8` | `not retained` | `ses_ecb21d7f0ffewYdWjqjTO4y2r7` |
| V2 reused pane, current occupant | `azure-damselfly` | `w70:p8` | `term_65db67e6db5a0324` | `ses_ecb1f56f9ffe2ff5lT159im0Gc` |
| V2 control | `olive-dodo` | `w70:p9` | `not retained` | `ses_ecb21d7f1ffeEaMC6ldibTf3nL` |
| Pi peer | `blue-cassowary` | `w70:p7` | `term_65db67e6d8da6323` | `2026-10-13T10-44-40-592Z_01a134dd-4c0c-73f6-8a93-887202ac2706.jsonl` |

The old and current `w70:p8` sessions are distinct. Herdr assigned both V2
addresses without an explicit alias. The lifecycle record for `lilac-rat`
reported `full_lifecycle_hook_authority` before these exchanges.

| Scenario | Sender and recipient | Evidence | Result |
| --- | --- | --- | --- |
| Same-pane reuse | `lilac-rat` -> `azure-damselfly` | `E2-D1-REUSED-NEW-20261013T1046Z` is a `[peer-message v1 ... kind=send]` user record in current session `ses_ecb1f56f9ffe2ff5lT159im0Gc`; it is absent from old session `ses_ecb21d7f0ffewYdWjqjTO4y2r7`. | Passed: delivery reached the new conversation, not its previous occupant. |
| V2 while recipient is working | `azure-damselfly` -> `lilac-rat` -> `azure-damselfly` | `lilac-rat` was `working` on a real `sleep 60` when `azure-damselfly` submitted `E2-D2-V2-ASK-DURING-A-BUSY-20261013T1050Z`. The queued user message later appeared in `lilac-rat`'s conversation. It then submitted `E2-D2-V2-REPLY-AFTER-BUSY-20261013T1050Z`, recorded in the recipient conversation. | Passed: submission while busy and later queued-message processing are both recorded. |
| Pi while recipient is working | `lilac-rat` -> `blue-cassowary` -> `lilac-rat` | `blue-cassowary` was `working` on a real `sleep 60` when `lilac-rat` submitted `E2-D2-PI-ASK-DURING-PI-BUSY-20261013T1055Z`. The Pi JSONL later records the peer user message and a successful `herdr-peer reply` with `E2-D2-PI-REPLY-AFTER-BUSY-20261013T1055Z`. | Passed: submission while busy and later queued-message processing are both recorded. |
| Negative control | `olive-dodo` | The control conversation contains none of the follow-up addressed markers. | Passed: no unrelated delivery observed. |

The durable follow-up controls record peer-command exits of `0`; their tool
results report `isError: false`. They preserve reproducible evidence without
persisting provider credentials or temporary home directories.
