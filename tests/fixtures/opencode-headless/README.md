# OpenCode transport fixture

`opencode.py` is a synthetic transport, not a model or a native server. It stores
minimal export data under `XDG_DATA_HOME`. This lets tests distinguish an existing
session from a missing one, and verify that a changed caller environment cannot
redirect resume to another store. Export failure never receives a run prompt.

## Pinned sources

V2 is pinned to `2.0.28`, commit
`026b106bc5d41b679ffc413264229c340871e4d3`:

- [`noninteractive.ts`](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/cli/src/run/noninteractive.ts):
  `emit` writes `{type, timestamp, sessionID, ...data}`. `reconcile` emits the
  unrendered suffix at `part.text`, with `messageID` and a projected part ID
  ending in `_text-<ordinal>`. Execution success has no required final JSONL
  event. SIGINT calls `session.interrupt`; TERM/HUP do not have that handler.
- [`index.ts`](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/cli/src/index.ts):
  `Effect.scoped` precedes the final `process.exit(process.exitCode ?? 0)`.
  Provider failure and the first handled SIGINT therefore close the owned scope
  before normal exit 1/130. A second SIGINT in `noninteractive.ts` instead calls
  `process.exit(130)` immediately; the helper forwards at most one.
- [`session-target.ts`](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/cli/src/session-target.ts):
  a missing explicit session can be created with the same requested ID.
- [`server-connection.ts`](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/cli/src/services/server-connection.ts),
  [`standalone.ts`](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/cli/src/services/standalone.ts),
  [`server-process.ts`](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/cli/src/server-process.ts):
  default connections use the background service; standalone uses a private
  server with a stdin lease. EOF closes its scope.
- [`cross-spawn-spawner.ts`](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/util/src/cross-spawn-spawner.ts):
  standalone's child runs detached on POSIX. The CLI process group alone cannot
  certify server or tool-process quiescence.
- [`session/export.ts`](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/cli/src/commands/handlers/session/export.ts),
  [`session-transfer.ts`](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/schema/src/session-transfer.ts),
  [`session.ts`](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/schema/src/session.ts):
  export returns `{info, messages}`; `info.id` and `info.location.directory`
  identify the saved session and its checkout.

V1 is pinned to `1.19.0`, commit
`733b2c627e5aec39cb33cc22373bdce33053ef2c`:

- [`run.ts`](https://github.com/anomalyco/opencode/blob/733b2c627e5aec39cb33cc22373bdce33053ef2c/packages/opencode/src/cli/cmd/run.ts):
  default runs use an in-process server; text events carry full parts with IDs.
- [`export.ts`](https://github.com/anomalyco/opencode/blob/733b2c627e5aec39cb33cc22373bdce33053ef2c/packages/opencode/src/cli/cmd/export.ts):
  `export <sessionID>` returns `{info, messages}`, with `info.directory`.
  The installed `1.19.0` help also confirms `--auto` and `--format=json`.

## Calibration boundary

A live isolated V2 `2.0.28` probe used the helper's public launch, resume, and
cleanup commands with anonymous `opencode/ling-3.1-flash-free`. Both turns returned
zero and the same native session. The second turn recalled a marker from the
first. A separate native export contained both user turns and assistant replies.
Its consumed fields matched the fixture's envelope and export fields. The probe
also observed real projected text IDs without a final `step_finish` event.
`opencode/cat-jam-free` returned a real `provider.no-route` error and exit 1.
A follow-up probe deleted only its own isolated native test session, then
observed helper resume exit 1 before any run prompt. A second native export
confirmed that the session had not been recreated; recovery state remained.

IDs, timestamps, omitted non-consumed fields, and text in the fixture remain
synthetic. The suffix case is a source-calibrated stress sequence, not a captured
model response. Its exact projected-ID/message pair is independently copied
from the live JSONL: `prt_138f1d3f2001Gg4faoD3R0Gy1E_text-0` with
`msg_138f1d3f2001Gg4faoD3R0Gy1E`. The ordinal separator is a hyphen, not an
underscore; the earlier fixture and parser shared that error. The corrected
fixture was red against the old parser before the parser changed.

The waiting fixture models the first handled SIGINT with an explicit teardown
marker, then exit 130. A second SIGINT bypasses that marker, as the pinned CLI
bypasses its scope. Provider/preflight errors have nearby successful retry and
cleanup controls. The tests do not infer active work from an export or another
private server. Hard-kill uncertainty remains an explicit failure retaining state.

A fresh V2 `2.0.28` live probe also observed provider failure (CLI 1) followed by
cleanup 0, and failed export preflight followed by cleanup 0. During a controlled
Python tool call, SIGINT produced CLI exit 130. The tool recorded SIGTERM; the
observed CLI, private server, and tool PIDs were absent after completion. The
same native session then resumed with exit 0 and recalled its earlier marker;
cleanup returned 0. This proves that probe's owned teardown, not arbitrary
detached daemon management. Live V1 interruption remains outside this evidence.

Behavioral oracle: the approved PR #479 lifecycle, refined by the follow-up's
server ownership, existing-session, and text reconstruction requirements.
Subprocess and Git worktree assertions use real local processes and repositories.
