# Model tiers

A skill that starts a child picks its model and reasoning effort by tier, never by name. The tier owns the effort or variant; the calling skill sets which tiers a role may use.

| Tier | Claude model / effort | OpenCode model / variant |
|---|---|---|
| `low` | `haiku` / `high` | `openai/gpt-6-luna` / `high` |
| `low+` | `haiku` / `xhigh` | `openai/gpt-6-luna` / `xhigh` |
| `medium` | `sonnet` / `high` | `openai/gpt-6.1-terra` / `high` |
| `high` | `opus` / `medium` | `openai/gpt-6.2-sol` / `medium` |
| `high+` | `opus` / `high` | `openai/gpt-6.2-sol` / `high` |

Verified on 2026-11-19 against Claude Code 2.1.311 and OpenCode 2.3.2.
