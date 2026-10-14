# Model tiers

A skill that starts a child picks its model and reasoning effort by tier, never by name. The tier owns the effort or variant; the calling skill sets which tiers a role may use.

| Tier | Claude model / effort | OpenCode model / variant |
|---|---|---|
| `low` | `haiku` / `high` | `openai/gpt-5.6-luna` / `high` |
| `low+` | `haiku` / `xhigh` | `openai/gpt-5.6-luna` / `xhigh` |
| `medium` | `sonnet` / `high` | `openai/gpt-5.6-terra` / `high` |
| `high` | `opus` / `medium` | `openai/gpt-5.6-sol` / `medium` |
| `high+` | `opus` / `high` | `openai/gpt-5.6-sol` / `high` |

Verified on 2026-10-14 against Claude Code 2.1.287. OpenCode column awaits re-verification on the installed OpenCode 2 version.
