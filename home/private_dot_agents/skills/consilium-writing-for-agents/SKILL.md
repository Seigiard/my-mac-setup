---
name: consilium-writing-for-agents
description: Review agent documents with two independent writing-for-agents reviewers, Claude Fable and OpenAI Astra, then reconcile their reports and apply what holds. Use when the user asks for a consilium, a Fable and Astra cross-check, or a second opinion on a skill, CLAUDE.md, AGENTS.md, or shared doc.
---

# Consilium: writing-for-agents

Two reviewers read the same documents against `writing-for-agents`, independently and read-only. You reconcile their reports and own every edit.

## Arguments

| Argument | Meaning |
|---|---|
| none | Agent documents changed in the working tree and on the branch against the default branch: `SKILL.md` files, `CLAUDE.md`, `AGENTS.md`, shared docs under `~/.claude/shared` or their chezmoi sources, and the files they point to. |
| paths | Exactly these files. |

## Reviewers

Both get the same prompt and run at the same time: two tool calls in one message.

| Reviewer | Inside herdr (`HERDR_ENV=1`) | Outside herdr |
|---|---|---|
| Fable | `bash ~/.agents/skills/ask-in-herdr/scripts/ask.sh claude "<prompt>" --model fable --effort medium --cwd "$PWD"` | Agent tool with `model: fable`, `effort: medium`, and the prompt. |
| Astra | `bash ~/.agents/skills/ask-in-herdr/scripts/ask.sh opencode "<prompt>" --model openai/gpt-6-astra --effort medium --cwd "$PWD"` | `env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID opencode run --model openai/gpt-6-astra#medium "<prompt>"` |

Inside herdr, read the `ask-in-herdr` skill for the outcome contract. Only `status=answered` yields a report. Any other status means that reviewer is absent: say so in the final report and reconcile the one report you have. Never write a report on a reviewer's behalf.

## Prompt

```text
Review these files as a reviewer of documents written for agents: <paths>, in <cwd>.
First read ~/.agents/skills/writing-for-agents/SKILL.md and SKILL-MECHANICS.md in the same folder, and judge strictly by those rules.
Report only actionable findings. For each: file and line, the rule it breaks (pointer wording, information hierarchy, co-location, completion criterion clarity or demand, negation, duplication, cache, leading word, sprawl), why it matters here, and the concrete rewrite.
Say "no findings" for a file that is clean. Keep the report under 60 lines. Change no files.
```

Add context a reader of only the files would miss: what the change is for, and which other documents it must agree with.

## Reconcile

1. **Merge** the reports into one table keyed by file and line, with a column for which reviewer raised each finding.
2. **Judge** each finding against the rule text and the file. Raised by both and supported by the rule: apply. Raised by one: apply only when the rule text supports it. Otherwise reject with the reason in one sentence. Done when every row is marked applied or rejected.
3. **Edit** the files for the applied rows.
4. **Report** to the user: the table with its verdicts, the absent reviewer if any, and the files you changed. Close each herdr tab with the `herdr-child reap` command its `ask.sh` run printed.

A peer report is input, not proof. The rule text decides.
