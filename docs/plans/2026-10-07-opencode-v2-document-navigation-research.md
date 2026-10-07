---
title: OpenCode V1 and V2 Document Navigation Interception - Research
type: research
date: 2026-10-07
topic: opencode-v2-document-navigation
status: complete
execution: none
---

# OpenCode V1 and V2 Document Navigation Interception

## Findings

**Official OpenCode 2 is publicly distributed. Its tool-transform API can wrap or replace the built-in reader and return a successful synthetic TOC without executing that reader. OpenCode 1.18.34 already supports same-name custom-tool overrides and argument mutation, although its before-hook alone cannot return a successful replacement.** [A1–A5, V1–V5, W1–W5]

This follows up [the Claude mods/Pi research](2026-10-07-document-navigation-interception-research.md). That note's OpenCode column describes this repository's blocking adapter, not the full OpenCode API. This note changes that capability assessment. It does not implement an adapter or change the scope of issue #409.

Evidence was collected on 2026-10-07. Local `opencode --version` returned **1.18.34**. No agent was launched. No package, configuration, issue, or existing file was changed. Examples below are source-derived fragments, not runtime demonstrations.

## Availability and source identity

| Classification | Verified evidence | Meaning |
|---|---|---|
| Released/current V1 | Local 1.18.34; GitHub `releases/latest` reports **v1.18.35**, published 2026-10-06 | Local and latest V1 are distinct. Interception source is pinned to local-version tag. [A1, V1] |
| Public/current V2 | Official V2 installation docs; npm `@opencode/cli@latest` = **2.0.24**; published `@opencode/plugin@2.0.24`; canonical tag `v2.0.24` | V2 is not merely a proposed branch or a third-party fork. Public availability is established independently of GitHub Releases. [A2–A5] |
| V2 development branches | Canonical repository has both `v2` and `2.0` | Branch existence alone is not release evidence. Inspected heads: `v2` = `2e3d3a735a06dc403a9dda03ae7b205bf1c0ec3a`; `2.0` = `7a6ce05d0939826aa6c8e1c481489a713b2d633f`. Main API analysis uses the tag, not either moving head. [A6] |
| Implemented V2 evolution | Tool-update/removal PR #45436 merged into `v2` on **2026-08-27** | Executor wrapping is implemented, not a roadmap promise. The PR explicitly describes Promise executor wrapping and last-valid-add-wins behavior. [R1] |
| Proposal / unsettled work | Member-authored #36462 asks how to normalize V2 MCP API naming “before the API stabilizes” | A concrete maintainer design question, not a commitment to a particular API or delivery date. [R2] |
| Uncertain | A dated future roadmap for Claude-style `next()` middleware or a before-tool synthetic-result field | No explicit maintainer delivery commitment found in the bounded search. This does not imply that none exists elsewhere. |

`gh api repos/anomalyco/opencode` returned canonical `full_name: anomalyco/opencode`, default branch `dev`. Querying historical `sst/opencode` resolves to that same repository. `has_discussions` is false. No owner migration away from Anomaly was observed. The published V2 CLI package points to this repository and identifies `thdxr` as its npm maintainer. [A3, A7]

**Why GitHub Releases is misleading here:** querying the release for `v2.0.24` returns 404, but the tag and npm artifacts exist. The pinned publish workflow explicitly says: “Unlike dev, V2 publishes a tag rather than a GitHub Release event.” It announces V2 releases after publication. [A4–A5]

Documentation has version drift. Tavily returned an older plugin-page snapshot marked beta, using `@opencode-ai/plugin` and `/v2` exports. A direct fetch of the same official URL returned the current `@opencode/plugin` API, matching the 2.0.24 package exports and tagged source. The directly fetched installation page also linked older 2.0.6 binaries while npm latest was 2.0.24. Use the pinned package/source contracts below; do not mix generations of examples. This research establishes public distribution, not a general API-stability guarantee. [A2–A3, W1]

## Capability matrix

“Supported” means inspected contract and implementation. It does not mean exercised locally.

| Capability | V1 1.18.34 | V2 2.0.24 | Remaining boundary |
|---|---|---|---|
| Mutate arguments before built-in read | Supported: mutate `output.args.filePath` in place | Supported: edit `event.input`; native read uses `path` | This still executes the reader against the replacement path. [V2, W2] |
| Return synthetic success from before-hook alone | No result/skip slot | No result/skip slot | Both hooks are mutation hooks, not Claude `next()` middleware. [V1, W2] |
| Fully replace named `read` | Supported: custom tools override built-ins in model tool map | Supported: `ctx.tool.transform`, `editor.add` or `editor.update` | Replacing a registry tool does not intercept arbitrary filesystem access. [V3–V4, W3] |
| Capture prior executor and delegate | No public original-reader handle found in V1 plugin contract | Supported: capture `tool.execute` inside `editor.update` | V2 captures the preceding definition, including earlier plugins, not an immutable pristine built-in. [W4] |
| Successful synthetic TOC without original-reader I/O | Supported through custom `read` replacement | Supported through executor wrapper/replacement | V1 pass-through needs extra design; V2 must satisfy retained output schema. [V4–V5, W4–W5] |
| Modify result after execution | `tool.execute.after` | `ctx.tool.hook("execute.after", ...)` | Does not avoid I/O. V2 error branch remains an error branch. [V2, W3] |
| Register a page/navigation tool | `tool: { name: ToolDefinition }` or tool file | `editor.add({ name, input, execute, ... })` | Neither native read schema has PDF `pages`; page extraction is separate work. [V5–V6, W6] |
| Session/subagent state | Closure keyed by `sessionID`; child sessions have `parentID` | Same; tool context also has `agent`, `messageID`, call `id`; plugin-scoped durable storage | No automatic once-per-document policy or atomic first-read transaction. [V5, V8, W7–W8] |
| Prompt/context transformations | `chat.message`, experimental messages/system/compaction hooks | `session.hook("prompt"/"context"/"compaction"/...)` | Outgoing context edits and pre-attachment input edits occur at different boundaries. [V1, W7] |
| Avoid server-side attachment loading | Not with `chat.message`: file resolution precedes it | Supported for prompt file URIs: prompt hook precedes materialization | Cannot undo client-side reads/uploads or already-encoded data URLs. [V7, W9] |
| SDK event subscription as interception | No | No | Event streams observe; in-process hooks/transforms control execution. [V1, W1] |

## V1: two available routes beyond the current adapter

### Argument redirection is already sufficient for an existing TOC

Exact relevant public signatures in `@opencode-ai/plugin` [V1]:

```ts
"tool.execute.before"?: (
  input: { tool: string; sessionID: string; callID: string },
  output: { args: any },
) => Promise<void>

"tool.execute.after"?: (
  input: { tool: string; sessionID: string; callID: string; args: any },
  output: { title: string; output: string; metadata: any },
) => Promise<void>
```

The dispatcher calls the before-hook with `{ args }`, then calls `item.execute(args, ctx)`, then the after-hook. It ignores hook return values. The plugin runner awaits hooks sequentially. Therefore mutate the existing argument object; replacing `output.args` with a new object is not enough for this dispatch path. [V2, V8]

Source-derived branch, with an already-selected existing `tocPath`:

```ts
output.args.filePath = tocPath
delete output.args.offset
delete output.args.limit
```

This produces a normal successful text read of the TOC, with no original PDF read by that invocation. Clearing ranges avoids applying PDF-request ranges to the TOC. It still does TOC I/O and ordinary reader work. Preserve the original PDF identity separately for first-read tracking. If index selection fails, leave arguments unchanged; a failure after redirection is not automatically retried against the PDF. Later plugins can also change the arguments. [V2, V6]

### Same-name custom read is a real override

The official custom-tool docs explicitly permit collisions. Source confirms both halves: registry `all()` returns built-ins followed by custom tools; session resolution assigns each one to `tools[item.id]`. Later assignments replace earlier ones. Plugin tools are appended after discovered tool files. Thus `.opencode/tools/read.ts` default export or `tool: { read: definition }` can replace the model-facing reader. [V3–V4]

The exact executor contract is `execute(args, context): Promise<ToolResult>`. `ToolResult` is either a string or `{ title?, output: string, metadata?, attachments? }`. Returning `tocText` is a successful result, not a denial. The adapter wraps it into the normal tool result and applies output truncation. `ToolContext` exposes `sessionID`, `messageID`, `agent`, `directory`, `worktree`, `abort`, `metadata(...)`, and `ask(...)`. [V4–V5]

The gap is delegation. V1 `PluginInput` and `ToolContext` expose no supported equivalent of Pi's original-read factory or V2's editor-provided executor. An internal `ReadTool` import depends on Effect services and is not a public original-reader API. Calling SDK `file.read` is a different operation, not proof of native read parity. A V1 override must own its fallback implementation or use a separately designed routing arrangement. A before-hook path rewrite is simpler when preserving native repeated reads is the goal. [V1, V5–V6]

V1's `tool.definition` only changes description/parameters, not `execute`. Experimental messages/system transforms can change model context, but supply neither a successful before-tool result nor universal pre-file interception. The messages-transform input is `{}`; session identity must come from message records rather than an invented input field. [V1]

## V2: native executable-tool wrapping

### Registration and exact API

V2 uses `import { Plugin } from "@opencode/plugin"` and `Plugin.define({ id, setup(ctx) })`. Effect plugins have the separate `@opencode/plugin/effect` entrypoint. `setup` can return cleanup; registration methods return a disposable registration. [W1–W2]

```ts
ctx.tool.transform(callback: (editor: ToolEditor) => void): Promise<Registration>
editor.get(id: string): (Info & { readonly id: string }) | undefined
editor.add(tool: Info): void
editor.update(id: string, update: (tool: Types.Mutable<Info>) => void): void
editor.remove(id: string): void

execute(input, context: ToolContext): Promise<Tool.Result<Output>>
```

`ToolContext` has `sessionID`, `agent`, `messageID`, call `id`, `signal: AbortSignal`, and `progress(update): Promise<void>`. A result has optional `output`, `content`, and `metadata`. `content` is a string or text/file content array. `output` is structured data governed by the tool's output schema. [W2, W5]

Source-derived wrapping fragment; `selectTocResult` below is proposed policy/cache code, not an OpenCode API:

```ts
await ctx.tool.transform((editor) => {
  editor.update("read", (tool) => {
    const previous = tool.execute
    tool.execute = async (input, context) => {
      const replacement = await selectTocResult(input, context)
      if (replacement) return replacement
      return previous(input, context)
    }
  })
})
```

The Promise adapter explicitly converts the previous Effect executor to a Promise executor, gives it to the update callback, then installs the modified executor. This supports real pass-through, including progress and cancellation. The synthetic branch never calls the previous reader. A later valid same-name `add` can replace this wrapper, and a later `update` can wrap it. Transforms replay in order on registry rebuild; capture `previous` inside the transform, not by recursively looking up the final named tool during execution. [W3–W4]

### Successful output must match the retained read schema

Native V2 read accepts `{ path, offset?, limit? }` and declares a union output schema: file, text page, or directory page. A wrapper that retains this schema cannot just return `{ content: tocText }`: runtime rejects a missing declared `output`. [W5–W6]

A source-derived synthetic **file** result can use the existing UTF-8 branch:

```ts
return {
  output: {
    type: "file",
    uri: tocUri,
    name: tocName,
    content: tocText,
    encoding: "utf8",
    mime: "text/markdown",
  },
  content: tocText,
  metadata: { navigation: "toc", sourcePath, truncated: false },
}
```

`tocUri`, `tocName`, `tocText`, and `sourcePath` describe the actual TOC and original document. They are supplied values, not APIs. This matches the inspected `FileContent`/`FileSystem.Content` structure and preserves the native output schema. Its final encoding and model-visible success still need a runtime observation. A new standalone tool without an output schema may instead return `{ content: tocText }`; it must not include an `output` property. [W5–W6]

### Before/after hooks are not continuation middleware

`ctx.tool.hook(name, callback)` awaits a callback returning `Promise<void> | void`. `execute.before` has mutable `tool` and `input`, plus readonly session/agent/message/call IDs. It has no `result`, `skip`, or `next`. V2 resolves the tool name after this hook, so redirection to another registered tool is also possible. Use a full executor wrapper for explicit original-reader pass-through. [W2–W3]

`execute.after` is a union: `{ status: "completed", result }` or `{ status: "error", error }`, plus call identity and input. Completed results can be replaced. On failure, core triggers the error hook and then returns `afterEvent.error`; it does not reselect the branch based on a changed status. Treat it as post-execution result/error editing, not a mechanism to turn a pre-tool rejection into success. [W3]

Unlike Claude's `next(e)`, the captured executor does not run a downstream runtime-hook chain. The outer dispatcher runs the before/after hooks around the selected executor. There is also no automatic short-budget fail-open policy in these signatures. Cache failures must be caught before delegation, with cancellation and a deadline owned by the navigation adapter. [W3–W5]

## Session state, model context, and attachments

Plugins are resident per loaded location/instance, not newly created for each session. A closure set needs at least `(sessionID, document identity)` keys. V1 task and V2 subagent implementations create child sessions with `parentID`; `agent` identifies the configured agent, not a unique child invocation. Use the child's session ID for independent navigation state, or deliberately resolve the parent/root to share it. [V8, W1, W8]

V2 `ctx.storage.get/set/remove/scan` provides plugin-scoped durable JSON storage. It is not automatically session-scoped, and the inspected interface has no compare-and-swap transaction. Define resume/fork/reload/compaction behavior explicitly. Reserve a first-read decision before asynchronous work if parallel calls must not both receive the TOC. These are proposed adapter responsibilities, not behavior supplied by the API. [W7–W8]

V2 `ctx.session.hook("context", ...)` gets `sessionID`, `agent`, `model`, mutable `system`, `messages`, `tools`, and `options`. It changes the outgoing agent-loop request, not stored history. Compaction, title, and transient generation have separate hooks. Context `tools` contain descriptions/input schemas, not executors: use the tool transform for replacement. Experimental WebSocket hooks edit handshake/frames; HTTP hooks edit provider traffic. Neither is needed for PDF-reader avoidance. [W1, W7]

**V2 has a concrete pre-attachment boundary.** `ctx.session.hook("prompt", ...)` sees mutable `{ text, files?, agents?, skills? }`, admission metadata, and delivery mode. Each file has `{ uri, name?, description?, mention? }`. Core waits for plugin activation, triggers this hook, and only then calls `materializeAttachment` for the edited files. Replacing a PDF `file:` URI with a TOC URI, or removing it and adding TOC text, avoids that server-side PDF materialization. Update mention offsets when changing text. [W7, W9]

This does not prevent bytes already read by a client to construct an upload/data URI. It also does not cover every synthetic/shell/control message: the official contract distinguishes those from `session.prompt` admission. Treat client upload avoidance as a separate investigation. [W1, W9]

V1 has the opposite timing: `resolvePart` completes before `chat.message`. PDF/file attachment handling can call `fsys.readFile` directly; text mentions use `registry.named().read`, which is the stored built-in rather than the overwritten model tool map. A custom `read` override therefore does not establish attachment coverage. [V7]

SDK events remain observational: V1 exposes `event({ event }): Promise<void>`; V2 exposes `ctx.event.subscribe({ signal? }): AsyncIterable<OpenCodeEvent>`. They have no awaited mutable decision object at the read boundary. Using an SDK to drive an application-owned prompt before submission is useful, but is not interception of every built-in call. [V1, W1]

## Implications for document navigation

1. **For installed V1, consider TOC-path redirection first.** It can already give success and avoid PDF I/O while keeping native read on subsequent calls. It requires an existing usable sidecar and explicit first-read state. This is an alternative to the current exception transport, not a deployed change.
2. **For V2, prefer `editor.update("read", ...)` for exact synthetic-first/read-through behavior.** Preserve the input/output schemas and capture the previous executor. Return an honest TOC result; delegate once on repeat or recoverable index failure.
3. **Keep TOC selection independent of client transport.** Index freshness, bounded lookup, canonical identity, and Markdown/page references remain shared policy/service work. None is supplied by a hook.
4. **A dedicated PDF page tool is possible on both versions.** Native V1/V2 reads have line ranges, not Claude's PDF `pages` argument. V2's native reader loads PDF bytes for model attachment; the navigation plugin must supply page extraction separately. [V6, W6]
5. **V2 prompt interception is a concrete later attachment option.** It improves the server-side boundary over the currently inspected Claude attachment metadata and Pi input surfaces, but does not establish universal client-side I/O suppression.
6. **Waiting for a hypothetical OpenCode 2 roadmap is unnecessary for this capability.** V2 replacement is public source and published API. Migrating the existing V1 adapter is still a separate task: entrypoint, config, field names, and result contracts differ. [W1–W2]

Before an implementation claim, observe successful synthetic output, no original PDF reader call, repeat pass-through, simultaneous first reads, missing/stale sidecar fallback, cancellation, and child-session state on the exact chosen build. Attachment evidence must identify the client and URI route. These are future proof obligations; no runtime test or benchmark was performed here.

## Roadmap search boundary

Checked official V1/V2 docs; canonical repository metadata and historical-owner resolution; paginated releases and branches; tags matching `v2`; npm publication metadata; V2 specs and publish workflow; GitHub issue searches for `"2.0"`, `"plugins" "v2"`, `roadmap`, `"short-circuit"`, and member `thdxr`'s `v2` issues; PR searches for tool updates and prompt hooks. Inspected #45436, #43137, #36462, and #36443. GitHub Discussions is disabled on this repository. Search results were used as leads, not as maintainer commitments.

The V2 specs index explicitly says the specs are **not a backlog** and that GitHub issues own active work. #36443 is contributor-authored event-stream scoping work, not a promised tool-middleware release. #36462 is member-authored but supplies no delivery date. No future date is inferred from branch names, merged work, user feature requests, or older beta documentation. No third-party product is needed to explain the verified V2 distribution. [R1–R4]

## Primary-source ledger

All web endpoints were read on 2026-10-07. Source links use immutable commit IDs. V1 tag `v1.18.34` resolves to `aec0b9a6d8898f68f923aaf08b7306d931fd9d76`; V2 tag `v2.0.24` resolves to `e7a34f09bfd9134dfade5a8ddb843f7030bc9a69`.

### Availability

- **A1:** [V1 latest release observed: v1.18.35](https://github.com/anomalyco/opencode/releases/tag/v1.18.35).
- **A2:** [Official V2 installation](https://opencode.ai/v2/docs/), [V1-to-V2 migration](https://opencode.ai/v2/docs/migrate-v1).
- **A3:** [Published CLI 2.0.24 metadata](https://registry.npmjs.org/@opencode/cli/2.0.24), [published plugin 2.0.24 metadata and exports](https://registry.npmjs.org/@opencode/plugin/2.0.24).
- **A4:** [Canonical V2 tag](https://github.com/anomalyco/opencode/tree/v2.0.24), [publication workflow: tag, not Release event](https://github.com/anomalyco/opencode/blob/e7a34f09bfd9134dfade5a8ddb843f7030bc9a69/.github/workflows/publish.yml#L664-L675).
- **A5:** [CLI publication and artifact upload](https://github.com/anomalyco/opencode/blob/e7a34f09bfd9134dfade5a8ddb843f7030bc9a69/packages/cli/script/publish.ts#L16-L123).
- **A6:** [V2 branch snapshot](https://github.com/anomalyco/opencode/tree/2e3d3a735a06dc403a9dda03ae7b205bf1c0ec3a), [2.0 branch snapshot](https://github.com/anomalyco/opencode/tree/7a6ce05d0939826aa6c8e1c481489a713b2d633f).
- **A7:** [Canonical repository metadata](https://api.github.com/repos/anomalyco/opencode), [historical owner endpoint](https://api.github.com/repos/sst/opencode).

### V1 contracts and implementation

- **V1:** [Public plugin types](https://github.com/anomalyco/opencode/blob/aec0b9a6d8898f68f923aaf08b7306d931fd9d76/packages/plugin/src/index.ts).
- **V2:** [Before → executor → after dispatch](https://github.com/anomalyco/opencode/blob/aec0b9a6d8898f68f923aaf08b7306d931fd9d76/packages/opencode/src/session/tools.ts#L92-L134).
- **V3:** [Official same-name precedence documentation](https://opencode.ai/docs/custom-tools/#name-collisions-with-built-in-tools).
- **V4:** [Registry order, plugin result conversion, and named built-ins](https://github.com/anomalyco/opencode/blob/aec0b9a6d8898f68f923aaf08b7306d931fd9d76/packages/opencode/src/tool/registry.ts).
- **V5:** [ToolContext, ToolResult, and execute signature](https://github.com/anomalyco/opencode/blob/aec0b9a6d8898f68f923aaf08b7306d931fd9d76/packages/plugin/src/tool.ts).
- **V6:** [Native reader and argument schema](https://github.com/anomalyco/opencode/blob/aec0b9a6d8898f68f923aaf08b7306d931fd9d76/packages/opencode/src/tool/read.ts).
- **V7:** [Attachment/direct-reader path](https://github.com/anomalyco/opencode/blob/aec0b9a6d8898f68f923aaf08b7306d931fd9d76/packages/opencode/src/session/prompt.ts#L808-L964), [chat.message after resolution](https://github.com/anomalyco/opencode/blob/aec0b9a6d8898f68f923aaf08b7306d931fd9d76/packages/opencode/src/session/prompt.ts#L995-L1009).
- **V8:** [Plugin instance lifecycle and sequential trigger](https://github.com/anomalyco/opencode/blob/aec0b9a6d8898f68f923aaf08b7306d931fd9d76/packages/opencode/src/plugin/index.ts), [child-session task implementation](https://github.com/anomalyco/opencode/blob/aec0b9a6d8898f68f923aaf08b7306d931fd9d76/packages/opencode/src/tool/task.ts).

### V2 contracts and implementation

- **W1:** [Current official plugin docs](https://opencode.ai/v2/docs/build/plugins), [version-pinned docs](https://github.com/anomalyco/opencode/blob/e7a34f09bfd9134dfade5a8ddb843f7030bc9a69/services/www/src/docs/content/build/plugins/index.mdx), [plugin migration](https://opencode.ai/v2/docs/build/plugins/migrate-v1).
- **W2:** [Promise tool API](https://github.com/anomalyco/opencode/blob/e7a34f09bfd9134dfade5a8ddb843f7030bc9a69/packages/plugin/src/promise/tool.ts), [registration signatures](https://github.com/anomalyco/opencode/blob/e7a34f09bfd9134dfade5a8ddb843f7030bc9a69/packages/plugin/src/promise/registration.ts), [Plugin.define and context](https://github.com/anomalyco/opencode/blob/e7a34f09bfd9134dfade5a8ddb843f7030bc9a69/packages/plugin/src/promise/plugin.ts).
- **W3:** [Tool hook execution, registry update, and snapshot dispatch](https://github.com/anomalyco/opencode/blob/e7a34f09bfd9134dfade5a8ddb843f7030bc9a69/packages/core/src/tool.ts#L103-L284), [hook runner](https://github.com/anomalyco/opencode/blob/e7a34f09bfd9134dfade5a8ddb843f7030bc9a69/packages/core/src/plugin/hooks.ts).
- **W4:** [Promise executor bridge](https://github.com/anomalyco/opencode/blob/e7a34f09bfd9134dfade5a8ddb843f7030bc9a69/packages/plugin/src/promise/adapter.ts#L249-L260), [editor update bridge](https://github.com/anomalyco/opencode/blob/e7a34f09bfd9134dfade5a8ddb843f7030bc9a69/packages/plugin/src/promise/adapter.ts#L465-L505).
- **W5:** [Tool context/result/schema](https://github.com/anomalyco/opencode/blob/e7a34f09bfd9134dfade5a8ddb843f7030bc9a69/packages/schema/src/tool.ts), [runtime output enforcement](https://github.com/anomalyco/opencode/blob/e7a34f09bfd9134dfade5a8ddb843f7030bc9a69/packages/core/src/tool/runtime.ts#L28-L60).
- **W6:** [Native V2 read](https://github.com/anomalyco/opencode/blob/e7a34f09bfd9134dfade5a8ddb843f7030bc9a69/packages/core/src/tool/plugin/read.ts), [read output schemas and PDF byte path](https://github.com/anomalyco/opencode/blob/e7a34f09bfd9134dfade5a8ddb843f7030bc9a69/packages/core/src/tool/read-filesystem.ts#L69-L148), [UTF-8 file structure](https://github.com/anomalyco/opencode/blob/e7a34f09bfd9134dfade5a8ddb843f7030bc9a69/packages/core/src/filesystem.ts#L53-L60).
- **W7:** [Session hook signatures](https://github.com/anomalyco/opencode/blob/e7a34f09bfd9134dfade5a8ddb843f7030bc9a69/packages/plugin/src/promise/session.ts), [durable storage interface](https://github.com/anomalyco/opencode/blob/e7a34f09bfd9134dfade5a8ddb843f7030bc9a69/packages/plugin/src/promise/storage.ts).
- **W8:** [Subagent creation and parent ownership](https://github.com/anomalyco/opencode/blob/e7a34f09bfd9134dfade5a8ddb843f7030bc9a69/packages/core/src/tool/plugin/subagent.ts#L110-L216).
- **W9:** [Prompt hook before attachment materialization](https://github.com/anomalyco/opencode/blob/e7a34f09bfd9134dfade5a8ddb843f7030bc9a69/packages/core/src/session/prompt.ts#L29-L90), [file attachment input shape](https://github.com/anomalyco/opencode/blob/e7a34f09bfd9134dfade5a8ddb843f7030bc9a69/packages/schema/src/prompt-input.ts).

### Roadmap and development evidence

- **R1:** [Merged tool-update/removal PR #45436](https://github.com/anomalyco/opencode/pull/45436). Its predecessor #45396 is closed, not the merged implementation to cite.
- **R2:** [Member thdxr's V2 API naming issue #36462](https://github.com/anomalyco/opencode/issues/36462).
- **R3:** [Contributor event-scoping issue #36443](https://github.com/anomalyco/opencode/issues/36443).
- **R4:** [V2 specifications: authority and backlog boundary](https://github.com/anomalyco/opencode/blob/e7a34f09bfd9134dfade5a8ddb843f7030bc9a69/specs/v2/README.md).
