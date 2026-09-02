---
title: "ui.notify is a no-op in Pi's headless print/JSON mode, so update failures still don't surface there"
short_description: "Pi's print/JSON (headless) extension runtime binds without a uiContext, so ui.notify silently no-ops there; the brew auto-updater's failure notifications never reach a scripted user running in that mode."
type: "follow-up"
category: "agent-platform"
tags: ["pi","headless","notifications"]
date: "2026-09-02"
status: "open"
priority: "medium"
---

## Why this exists

Repository issue 2026-08-21-022 fixed home/dot_pi/agent/extensions/brew-auto-update/index.ts so every terminal update result (failure, skip, contention, up-to-date, updated) is routed through ui.notify via a finish/shouldNotify helper pair, instead of being silently discarded. That fix relies entirely on ui.notify as its delivery channel: the module-level notify(ui, message, level) helper (index.ts, wraps ctx.ui.notify in a try/catch so a throwing UI cannot break the updater) has no other way to surface a result. Tracing through the installed @earendil-works/pi-coding-agent package shows that in print/JSON mode, Pi's extension runtime binds extensions without a uiContext, so ExtensionUIContext.notify resolves to the package's noOpUIContext, where notify is a literal no-op. session_start still runs the update steps in that mode -- it just cannot report a failure there. This is pre-existing behavior in the Pi SDK, not something introduced by 2026-08-21-022's diff, but that diff makes it consequential for the first time: ui.notify is now the sole channel this extension uses to surface a broken Homebrew, a failing pi update --extensions, or a persistent timeout, and print/JSON mode is exactly the mode a scripted or automated user runs in. So the defect that 2026-08-21-022 set out to fix (silent updater failures) remains unresolved for anyone running Pi headlessly.

## Scope

home/dot_pi/agent/extensions/brew-auto-update/index.ts -- specifically the module-level notify(ui, message, level) helper that both call sites (session_start and the /brew-auto-update-now command, by way of the finish/shouldNotify pair) rely on exclusively. A fix needs a delivery channel that does not depend on an interactive UI context -- for example, persisting the terminal result to session state (such as an appendEntry-style call) so a headless/scripted caller can observe it after the fact, or another mechanism Pi's extension API exposes for print/JSON mode. Does not require touching the notification policy settled in 2026-08-21-022 (startup notifies on every failure, warning level, manual always reports) -- this is about the delivery channel, not when or at what level to notify.

## Open decisions

None.
