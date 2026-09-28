---
title: nono confinement for revmux - Research
type: research
date: 2026-09-28
topic: revmux-nono
status: complete
execution: none
---

# nono confinement for revmux

## Scope and evidence

Official nono documentation and source only for the independent research. No agents, sandbox probes, tests, installations, or config changes were run. Upstream test files were read as source, not executed. This note establishes documented mechanisms and source behavior, not a working integration.

nono source is pinned to `c40844c8affca10454ce483252110571623a80cb`, the upstream HEAD returned during research. Documentation URLs are live and may drift; the installed nono version and its behavior were not established.

### Supplied revmux baseline

The already verified installed version is `v0.2.5-d1f8680-20260922T183815`; supplied upstream HEAD is `d1f8680e68d598cdc235b92f24adab17ad9fa423`. Installation provenance was not rechecked here. Upstream permalinks confirm the relevant launch shape:

- [`claude.go`](https://github.com/umputun/revmux/blob/d1f8680e68d598cdc235b92f24adab17ad9fa423/app/executor/claude.go#L63-L81): `--permission-mode auto`, tools `Bash,Read,Grep,Glob,WebFetch,WebSearch`, strict MCP, and project settings only.
- [`codex.go`](https://github.com/umputun/revmux/blob/d1f8680e68d598cdc235b92f24adab17ad9fa423/app/executor/codex.go#L111-L115): `exec --sandbox read-only` by default.
- [`proc.go`](https://github.com/umputun/revmux/blob/d1f8680e68d598cdc235b92f24adab17ad9fa423/app/executor/proc.go): directly launches the `claude`/`codex` executable selected by each executor, supplies stdin and environment, parses stdout, and manages process-group cleanup.

## Verified nono facts

### Process tree and platforms

- **The boundary follows the launched process and its descendants.** Linux uses Landlock; macOS uses Seatbelt through `sandbox_init()`. A restricted child cannot remove its kernel policy, and descendants inherit it. This is same-host capability confinement, not a separate kernel or VM. [Security model](https://nono.sh/docs/cli/internals/security-model.md), [Seatbelt](https://nono.sh/docs/cli/internals/seatbelt.md).
- **The nono supervisor is outside that boundary.** `nono run` retains a trusted, unsandboxed parent for audit, proxy, diagnostics, optional rollback, and supported delegation. It can launch policy-selected command sandboxes; Linux capability elevation can supply approved file descriptors. Thus “the child cannot widen its own kernel policy” does not mean “the session can never receive more authority.” [Security model](https://nono.sh/docs/cli/internals/security-model.md).
- **`nono wrap` is a distinct execution mode.** It applies confinement and directly execs the target, leaving no nono parent. It omits audit, rollback, expansion, diagnostics, and proxy services. `run` documents signal forwarding, but that alone does not prove compatibility with revmux's cleanup and stream handling. [Execution modes](https://nono.sh/docs/cli/features/execution-modes.md).
- **Linux guarantees depend on kernel features.** Landlock starts at Linux 5.13; truncation control requires ABI v3, TCP controls v4, and signal/abstract Unix-socket scoping v6. Current source probes the available ABI and contains seccomp network fallback paths; the older docs' “warn only on old kernels” wording is not a complete description of current code. [Landlock docs](https://nono.sh/docs/cli/internals/landlock.md), [pinned Linux implementation](https://github.com/nolabs-ai/nono/blob/c40844c8affca10454ce483252110571623a80cb/crates/nono/src/sandbox/linux.rs).

### Filesystem grants and secret limits

- Grants distinguish read, write, read+write, and file versus directory access. On Linux, directory grants cover descendants, including newly created files; file grants bind to inodes and can become stale after replacement. Read grants also include execute permission. Base policy adds runtime/system access, so the effective sandbox is larger than the explicitly named repository. [Landlock docs](https://nono.sh/docs/cli/internals/landlock.md), [profiles](https://nono.sh/docs/cli/features/profiles-groups.md).
- **macOS supports deny-within-allow; Linux Landlock does not.** Current nono rejects a denied descendant beneath a granted directory on Linux with `Landlock deny-overlap ... Refusing to start with conflicting policy`. It does not implement a portable “read the entire repository except secrets” subtraction. The profiles page still says overlaps produce warnings; the pinned implementation is stronger. [Validator](https://github.com/nolabs-ai/nono/blob/c40844c8affca10454ce483252110571623a80cb/crates/nono-cli/src/policy.rs#L1584-L1643), [upstream regression source](https://github.com/nolabs-ai/nono/blob/c40844c8affca10454ce483252110571623a80cb/crates/nono-cli/tests/deny_overlap_run.rs).
- macOS deny-glob coverage includes files created after startup, according to upstream regression source. Allow globs are load-time snapshots. This is source evidence, not a local enforcement result. [Glob regression source](https://github.com/nolabs-ai/nono/blob/c40844c8affca10454ce483252110571623a80cb/crates/nono-cli/tests/glob_deny_after_start_run.rs).
- Built-in denials name known credential stores, keychains, browser data, shell configs, and history. They are path rules, not secret-content detection. For example, the policy names `~/.env` and `~/.envrc`, not every repository's nested `.env`. A secret in an otherwise readable file remains readable. Explicit `bypass_protection` can exempt a protected path but does not itself grant access. [Pinned policy](https://github.com/nolabs-ai/nono/blob/c40844c8affca10454ce483252110571623a80cb/crates/nono-cli/data/policy.json#L7-L144), [profile composition](https://nono.sh/docs/cli/features/profiles-groups.md).
- **Filesystem restrictions do not scrub inherited secrets.** Without an environment allowlist, ordinary parent environment variables pass through, subject to nono's dangerous-variable blocklist. Injected environment credentials intentionally reach the child; proxy-based injection instead keeps real credentials in the supervisor. Neither path denial nor read-only access means secret-free execution. [Environment filtering](https://nono.sh/docs/cli/features/environment.md), [credential boundary](https://nono.sh/docs/cli/internals/security-model.md#credential-isolation).
- Network and IPC need their own policy. Default profiles permit network access. Linux pathname Unix-socket mediation is opt-in; a reachable host service can expose authority beyond file reads. The current macOS page's “binary network control only” text conflicts with newer proxy documentation and should not be treated as the current feature ceiling. [Profiles](https://nono.sh/docs/cli/features/profiles-groups.md), [Linux IPC limits](https://nono.sh/docs/cli/internals/landlock.md#pathname-unix-socket-mediation), [proxy model](https://nono.sh/docs/cli/internals/security-model.md#network-proxy-security-model).

## Wrapper placement: deductions, not validated integration

| Placement | Expected benefit from documented inheritance | Tradeoff / unverified boundary |
|---|---|---|
| Whole revmux under nono | Constrains revmux and its directly launched reviewers and tools under one outer policy. No per-child interception is needed for inheritance. | The shared policy must accommodate controller output/state and both clients. Those shared grants are also available to descendants unless further restricted. Controller archive and lifecycle operations now face the sandbox. |
| Each Claude/Codex child under nono | Keeps revmux outside; permits different client policies and excludes controller-only filesystem grants from reviewer sandboxes. | Requires reliable interception of the direct executable launches. The controller remains trusted and unrestricted. Added supervisors may affect stream parsing, exit status, watchdogs, and process-group cleanup. |

`run` versus `wrap` is a separate choice from placement. `wrap` avoids an extra long-lived supervisor but cannot provide proxy-based credential isolation. `run` provides those services with a trusted host-side component. These deductions follow from [execution modes](https://nono.sh/docs/cli/features/execution-modes.md) and the pinned revmux launch code above.

An outer nono boundary would constrain Claude's Bash descendants independently of Claude's application permission mode. It would also surround Codex's existing read-only sandbox. However, nono's official [Codex guide](https://nono.sh/docs/cli/clients/codex.md) recommends a single sandbox layer with Codex's sandbox disabled. That recommendation is not evidence that the supplied revmux combination works, nor a reason here to weaken its default. The guide's stock profile grants writable workspace and client state; it is not a read-only review policy.

## Remaining unknowns

- Which nono release and signed profile versions would be selected, and whether they contain the pinned-source behavior.
- Whether either placement works with the installed clients, especially nested Codex sandboxing on macOS/Linux, noninteractive authentication, and revmux's process lifecycle.
- The minimal effective runtime, state, output, network, and IPC grants for this machine. Built-in profiles do not establish that minimum.
- Which secret-bearing files and environment variables exist in the actual review context. Linux broad repository grants cannot safely rely on denied descendants as exclusions; a narrower readable input set may be necessary.
- Whether credentials would remain client-readable or be brokered. Stock client state grants and a filesystem denylist alone do not establish credential isolation.

**Conclusion:** nono has the documented process-tree mechanism needed for an outer revmux boundary or per-child boundaries. The decisive policy constraint is Linux's lack of deny-within-allow; the decisive integration uncertainty is client and supervisor composition. Neither integration was executed or certified by this research.
