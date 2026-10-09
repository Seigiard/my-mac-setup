# Model tiers

A skill that starts a child picks its model by tier, never by name. This table is the one place a tier becomes a model. Read by the `tdd` skill, which also sets which tiers a role may use.

| Tier | Claude model | OpenCode model |
|---|---|---|
| `low` | `sonnet` | `openai/gpt-5.6-luna` |
| `medium` | `sonnet` | `openai/gpt-5.6-terra` |
| `high` | `opus` | `openai/gpt-5.6-sol` |
| `xhigh` | `fable` | `openai/gpt-6-astra` |

Mapping `external-leg-models/2026-09-12`, verified against Claude Code 2.1.236 and OpenCode 1.18.30. Claude has no cheaper step than `sonnet`, so `low` and `medium` share it; a role that needs a real `low` runs on OpenCode.
