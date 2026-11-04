---
name: consilium-writing-for-agents
description: Review agent documents with two independent writing-for-agents reviewers, Claude Fable and OpenAI Astra, then reconcile their reports and apply what holds. Use when the user asks for a consilium, or for Fable and Astra together, on a skill, CLAUDE.md, AGENTS.md, or shared doc.
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

| Reviewer | Inside the Herdr app (`HC_TERMINAL_ID` set) | Outside Herdr |
|---|---|---|
| Fable | `hc run --bg --json --name <alias> --cwd "$PWD" -- claude --model fable --effort medium --disallowed-tools Edit Write NotebookEdit AskUserQuestion`; then `hc wait <address>`, `hc send --json <address> "<prompt>"` and check `sent` (on false: `hc read <address>` first, resolve readiness, never blind-resend); then collect as below. | Agent tool with `model: fable`, `effort: medium`, and the prompt. |
| Astra | `hc run --bg --json --name <alias> --cwd "$PWD" -- env OPENCODE_CONFIG_CONTENT='{"model":"openai/gpt-6-astra","permission":{"question":"deny","edit":"deny"},"agent":{"build":{"model":"openai/gpt-6-astra","variant":"medium","permission":{"question":"deny","edit":"deny"}}}}' opencode --standalone`; then `hc wait <address>`, `hc send --json <address> "<prompt>"` and check `sent` the same way; then collect as below. | `env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID opencode run --model openai/gpt-6-astra#medium "<prompt>"` |

Collect each reviewer with `hc wait --json --timeout 1800 <address>`, then `hc get <address>` and branch on its status: `idle` or `done` means the report is in `hc read --lines 2000 <address>`; `blocked` means a dialog is open: `hc read <address>`, clear it (for example `hc keys <address> down enter`), wait again; `working` after the timeout gets one more wait, then the reviewer is absent: name it in the final report and reconcile the reports you have. Clean up only a terminal whose status is `idle`, `done` or `exited`: `hc kill <address>`, then `hc rm <address>`. A `working` or `blocked` terminal stays and is named in the report.

## Prompt

```text
Review these files as a reviewer of documents written for agents: <paths>, in <cwd>.
First read ~/.agents/skills/writing-for-agents/SKILL.md and SKILL-MECHANICS.md in the same folder, and judge strictly by those rules.
Report only actionable findings. For each: file and line, the rule it breaks (pointer wording, information hierarchy, co-location, completion criterion clarity or demand, negation, duplication, cache, leading word, sprawl), why it matters here, and the concrete rewrite.
Say "no findings" for a file that is clean. Return the report only; the caller owns every edit.
```

Add context a reader of only the files would miss: what the change is for, and which other documents it must agree with.

## Reconcile

1. **Merge** the reports into one table keyed by file and line, with a column for which reviewer raised each finding. Done when every finding from either report has a row; findings on one file and line share a row.
2. **Judge** each row against the rule text and the file. Accept it when the rule text supports it, whoever raised it; otherwise reject it with the reason in one sentence. Done when every row is marked accepted or rejected.
3. **Edit** the files for every accepted row. Mark a row applied once the resulting text carries its rewrite. Done when every row is applied or rejected.
4. **Report** to the user: the table with its verdicts, the absent reviewer if any, and the files you changed.
