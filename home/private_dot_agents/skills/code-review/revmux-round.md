# revmux round reference

Reached from `code-review` step 2 on the revmux route. The command itself is in `SKILL.md`; this file holds the candidate-file format and how to read a finished round.

## `--candidate`

When a round reviews values that do not live in Git, such as artifact checksums, digests, or
version strings, write them as a flat JSON object and pass `--candidate <file>` instead of
putting them in `--note`. Candidate keys must match `[A-Za-z0-9_.-]+`; values must be non-empty,
single-line strings. The rendered Candidate section counts toward the 1500-character scope
limit. Use `--note` for prose about what changed since the previous round.

## Reading a finished round

With `--wait`, the command blocks until the `.exit` file exists; run it detached and read `.exit`
afterwards. Keep report JSON and progress logs separate. `.exit` `0` and `1` are completed
reviews; anything else is a tool failure. A tool or launcher error, malformed output, missing sources, or non-empty
`sources.degraded` means incomplete coverage: report the failure and stop rather than claiming
convergence. For a healthy `raised 0` source, name the source and inspect its `agents/<name>.*`
tee; treat it as incomplete only when the tee shows that the agent could not work.
