---
title: "se-code-review accepts two identical peer reports as cross-model consensus"
short_description: "Nothing in the peer lifecycle compares the two reports, so a peer that returns the other's text is read as perfect agreement and silently halves coverage; the 2026-09-06 agent-hooks review produced byte-identical claude.report and opencode.report, and the run_id collision originally blamed is disproved - run_id is timestamp plus four random bytes, and identical inputs demonstrably produced distinct run directories."
type: "bug"
category: "se-pipeline"
tags: ["se-code-review","herdr-peers","review-coverage"]
date: "2026-09-06"
status: "open"
priority: "high"
---

## Why this exists

`se-code-review` exists to run the same review through two different models so
disagreement between them is visible. On 2026-09-06 it ran over the agent-hooks
migration and both peers returned the same file:

```
4e24f1e031202b5e8a6e66699766b59bee12f597da76c98682206294d03cdab2  claude.report
4e24f1e031202b5e8a6e66699766b59bee12f597da76c98682206294d03cdab2  opencode.report
```

Same nine reviewers, same four findings. The OpenCode peer performed no
independent review.

The failure is silent and it inverts the wrapper's purpose. Nothing errors, both
peers report `status: complete`, and the synthesis step sees perfect agreement on
every finding. Read naively that is the strongest possible signal, when in fact
coverage was halved. A reviewer trusting cross-model consensus is more misled by
this bug than by an outright peer failure, which the wrapper already detects and
reports as degraded coverage.

## The run_id collision is disproved (2026-09-06)

This record originally blamed a shared artifact directory: both peers deriving
the same `ce-code-review` `run_id` from identical review inputs, the second
finding a complete artifact and returning it. That mechanism does not exist.

`run_id` is not derived from the inputs. It is a timestamp plus four random
bytes, minted per invocation at
`~/.agents/skills/ce-code-review/references/select-and-route.md:111`:

```
RUN_ID=$(date +%Y%m%d-%H%M%S)-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' ')
```

The OpenCode-side copy at `~/.config/opencode/skills/ce-code-review/SKILL.md:439`
uses the identical derivation. Two peers cannot collide on it.

The surviving run directories under `/tmp/compound-engineering-501/ce-code-review/`
say the same thing directly. Two-peer runs on 2026-09-05 produced two *distinct*
run directories from identical inputs — `20260905-105630-676286f0` and
`20260905-105740-40470bcc`, both recording `branch: mise-setup-simplification-report`
and `head_sha: afb16aac` in `metadata.json`; the same pattern repeats for the
`ce-debug-herdr-version-argument` pair at `ffe5ca89`. Identical inputs do not
produce identical run ids.

For the incident itself there is exactly **one** run directory,
`20260906-092108-e7c0b2f5`. The OpenCode peer did not arrive second and find a
complete artifact; it produced no `ce-code-review` run at all.

The true cause is not recoverable. `home/private_dot_claude/shared/herdr-peer-launch.md:166-178`
deletes the transport directory and closes both tabs before synthesis, by design,
so the OpenCode peer's actual output is gone. Two unverified candidates remain on
record: the peer read the newest existing directory instead of running the skill,
or the lifecycle's bash blocks — written as one continuous shell but executed as
a fresh shell per tool call — lost `$OPENCODE_REPORT_PATH` and collapsed the two
paths into one.

## Scope

Make an identical pair of reports detectable rather than silently accepted. This
is deliberately a detection guard and not a cure: it is correct under either
unverified cause, and under any third cause not yet imagined.

- In the "Wait and collect" step of `home/private_dot_claude/shared/herdr-peer-launch.md`,
  compare the two collected reports before synthesis.
- Treat a byte-identical pair as degraded single-source coverage, the same way
  the lifecycle already treats a malformed peer report, and say so in the
  synthesis output rather than presenting agreement.
- The guard belongs in the shared lifecycle, not in one wrapper, so all three
  `se-*` workflows inherit it from one place.

Do not scope artifact paths by peer or mint per-peer run ids. Both target the
collision the evidence rules out.

The wrapper's real path is `home/private_dot_agents/skills/se-code-review/SKILL.md`;
the path this record originally named under `home/private_dot_claude/skills/` was
deleted in `b880a43` on 2026-08-31 and only a symlink stub remains there.

## Sibling workflows

- `se-simplify` cannot share the defect. Upstream `ce-simplify-code` has no
  scratch artifact root at all.
- `se-doc-review` is differently exposed, and arguably worse. Upstream
  `ce-doc-review` never defines how its `<run-id>` is generated —
  `~/.agents/skills/ce-doc-review/references/cross-model-review.md:126` interpolates
  the value with no minting recipe — and the directories on disk carry
  agent-invented semantic names (`mise-plan-doc-review`, `misplan-0906`). Two
  peers reviewing the same document could plausibly invent the same name. This is
  a genuine collision surface, unlike the one this record originally alleged, but
  no instance of it firing has been observed.

## Open decisions

- Whether the same detection guard should also flag a near-identical pair, not
  only a byte-identical one. A peer returning the other's report through a
  re-wrap would differ in whitespace and defeat an exact comparison.
