# herdr-caffeinate

A [herdr](https://herdr.dev) plugin that keeps macOS awake **only while at least
one agent is working**, and releases the wake lock the moment every agent goes
quiet. No more babysitting `caffeinate` by hand while agents run unattended.

## How it works

Herdr emits a global `pane.agent_status_changed` event whenever any agent's
semantic status changes (`working` / `idle` / `blocked` / `done` / `unknown`).
On every such event the plugin **reconciles**: it asks `herdr agent list` for
the current state of all agents and makes the world match — holding a single
`caffeinate` process if any agent is in an "awake" state, releasing it otherwise.

Reconciling from the authoritative list (instead of counting events) makes it
idempotent and self-healing: closed panes, missed events, and duplicate events
all resolve correctly, and exactly one `caffeinate` runs at a time.

The `caffeinate` process is started with `-w <herdr-pid>`, so if herdr itself
crashes the wake lock is released automatically.

Because it's event-driven, the lock is (re)established on the **next** agent
status change. If an agent is already mid-work the instant you enable the plugin,
the lock is taken a moment later when it next flips state — agents transition
constantly, and idle-sleep needs minutes of inactivity anyway, so there's no
practical gap.

## Requirements

- macOS (uses the built-in `caffeinate` and `pmset`)
- herdr ≥ 0.7.0
- `jq` optional (a `plutil`-free grep fallback is used when `jq` is absent)

## Install

```sh
herdr plugin link .                             # local dev (run from the clone)
herdr plugin enable keepawake.caffeinate
herdr plugin list                               # confirm it's enabled
```

Then just use herdr normally. When an agent starts working the Mac stays awake;
when the last one stops, it's free to sleep again.

## Actions

Run from the herdr command palette, or manually:

```sh
sh actions.sh status   # is the lock held? which agents are keeping it awake?
sh actions.sh stop     # force-release now (auto-resumes on next status change)
sh actions.sh test     # self-test: hold caffeinate, verify pmset assertion, release
```

## Configuration

Edit `~/.config/herdr-caffeinate/config.sh` (auto-created on first run from
[`config.example.sh`](./config.example.sh)):

| Variable           | Default     | Meaning |
|--------------------|-------------|---------|
| `AWAKE_STATES`     | `working`   | Space-separated agent states that hold the lock. Add `blocked` to also stay awake while an agent waits on you. |
| `CAFFEINATE_FLAGS` | `-di`       | `-di` = prevent system idle sleep and keep the display on. `-i` = system only (screen may sleep). `-is` = only hold on AC power (sleeps on battery). |

## Verify

```sh
# all agents idle -> no caffeinate assertion from us:
pmset -g assertions | grep -i 'caffeinate command-line tool'

# send a prompt to any agent (it goes "working"):
herdr agent list                       # shows "agent_status":"working"
pmset -g assertions | grep -i caffeinate   # our assertion now present

# let all agents finish -> assertion disappears.
```

## Uninstall

```sh
herdr plugin disable keepawake.caffeinate
herdr plugin unlink keepawake.caffeinate
```

Any active wake lock is released on the next status change, or immediately with
`sh actions.sh stop` before disabling.

## Files

| File                 | Purpose |
|----------------------|---------|
| `herdr-plugin.toml`  | Manifest: the `pane.agent_status_changed` hook + actions. |
| `reconcile.sh`       | Event hook entrypoint. |
| `lib.sh`             | Shared helpers: config, locking, pid management, state query, reconcile. |
| `actions.sh`         | `status` / `stop` / `test` actions. |
| `config.example.sh`  | Config template. |
