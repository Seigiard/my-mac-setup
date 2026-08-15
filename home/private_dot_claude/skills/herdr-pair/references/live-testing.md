# Live testing the pair (manual E2E)

CI covers structure, shellcheck, and `recv.sh`/`session.sh` units. The live pair needs herdr plus interactive agents, so a change to `herdr-pair` is validated by hand inside herdr:

1. **claude↔claude.** From a claude pane: `/herdr-pair --with claude <a trivial task, e.g. "add a one-line code comment to FILE and confirm">`. Confirm: a partner pane spawns and reaches idle; the task is delivered; the partner replies `[pair b -> a …]`; the loop iterates to **both sides `accepted`**; the handoff summary prints; the session dir is trashed.
2. **claude↔pi.** Same, `--with pi`. Additionally confirm pi got the protocol (its first reply is correctly formatted) and is idle-detectable.
3. **Isolation.** Run two pairs in two tabs of one workspace at once; confirm their session dirs (`<ws>/<tab_slug>/`) stay separate and neither closing trashes the other.

Probe-verified (2026-06-28, herdr 0.7.1): pi accepts the protocol via `--append-system-prompt <path>`, submits on a single Enter, is idle-detectable on its v2 hook, and replies in-format. Re-confirm after a herdr upgrade.
