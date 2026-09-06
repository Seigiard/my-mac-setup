---
title: Flattened argv overflows the per-string exec limit, not ARG_MAX
date: 2026-09-06
category: test-failures
module: testing
problem_type: test_failure
component: testing_framework
symptoms:
  - "An unrelated, innocent binary fails with fork/exec argument list too long, raised from inside a chezmoi template output call"
  - "The named binary runs fine by hand and in the same run's plain chezmoi apply; only the test-harness invocation fails"
  - "Rebuilding the container from scratch and stashing the branch's changes reproduce the identical failure, ruling out image and branch state"
  - "The first hypothesis blames total environment size, because nobody measures which single entry is oversized"
root_cause: resource_limit
resolution_type: test_fix
severity: high
related_components:
  - "tooling"
  - "development_workflow"
tags:
  - chezmoi
  - argument-list-too-long
  - max-arg-strlen
  - exec-limits
  - e2big
  - test-harness
  - environment-size
---

# Flattened argv overflows the per-string exec limit, not ARG_MAX

## Problem

`tests/helpers/chezmoi-unattended`'s `host-partial` diff profile cannot run `chezmoi diff` over the whole tree, because a handful of secret-bearing targets listed in an inventory must be excluded. It enumerates every managed target (`tests/helpers/chezmoi-unattended:209-215`), filters the inventory destinations out, and passes the survivors back as explicit target arguments to one `chezmoi diff`.

That is a caller-controlled, unbounded fan-out: the argument list grows with the managed set. Nothing regressed — the managed tree simply grew past a threshold nobody was tracking, and `make test-ubuntu` began failing deterministically, blocking the repo's deployment-sensitive verification gate for every PR that touched a managed path.

The trap is not "too many arguments". Chezmoi joins its entire argv into one string and exports it to every template subprocess as `CHEZMOI_ARGS`. Verified against the installed chezmoi v2.72.1:

```
$ chezmoi execute-template '{{ env "CHEZMOI_ARGS" }}'
chezmoi execute-template {{ env "CHEZMOI_ARGS" }}
```

A wide argv therefore does not merely consume the process's total argument space. It concentrates into a *single* environment string, and Linux caps single strings far below the total.

## Symptoms

`make test-ubuntu` failed two `tests/bashunit/templates_test.sh` zshenv assertions, identically on every run:

```
chezmoi: .chezmoiscripts/3-setup-herdr-integrations.sh: template: .chezmoiscripts/run_onchange_after_3-setup-herdr-integrations.sh.tmpl:10:45: executing ".chezmoiscripts/run_onchange_after_3-setup-herdr-integrations.sh.tmpl" at <output "herdr" "--version">: error calling output: /home/linuxbrew/.linuxbrew/bin/herdr --version: fork/exec /home/linuxbrew/.linuxbrew/bin/herdr: argument list too long
```

`herdr --version` is two short arguments. The named binary was entirely innocent. Its call site is the hash-trigger comment at `home/.chezmoiscripts/run_onchange_after_3-setup-herdr-integrations.sh.tmpl:10`, which exists only so chezmoi re-runs the script when herdr is upgraded.

One tell pointed away from the named binary: `chezmoi apply --verbose` inside the same `test-ubuntu` run executed the same template without failing. Only the `templates_test.sh` invocations routed through the `host-partial` diff launcher failed.

## What Didn't Work

**The recorded hypothesis was wrong.** The investigation's first suspect was bashunit: `tests/lib/bashunit -j 8` runs parallel workers and the framework `export -f`s its assertion helpers, so the guess was that the inherited environment had grown past `ARG_MAX` in aggregate. That hypothesis is plausible and points at a real mechanism, but it is not what happened. Shrinking the inherited environment would have bought headroom without removing the failure, because the binding constraint was one oversized entry, not the sum.

**Isolation was thorough and still did not name the cause.** Every reproduction gave the identical failure at the identical location — the original run, plus three isolation variants:

- with an unrelated in-progress plan diff applied;
- with that diff stashed back to the already-committed state — ruling out a code regression;
- after a full `docker compose build --no-cache test-ubuntu` — ruling out a stale Docker layer.

That eliminated the two cheapest explanations, which is real diagnostic value. But elimination is not identification. The move that resolved it was measuring *which single environment entry* was oversized rather than measuring the total. `CHEZMOI_ARGS` came back at 464,434 bytes — roughly 3.5x the per-string limit, while still comfortably under the total. That figure is a one-time runtime measurement of the tree as it stood, not a constant defined anywhere in the repository; it will drift as the managed set changes.

## Solution

Cap the argument list at the boundary that builds it, and size the cap against the **per-string** limit rather than the total. The fix precomputes the fixed cost of every invocation, then flushes a batch whenever the next target would cross the budget (`tests/helpers/chezmoi-unattended:194-253`):

```bash
if [ "$profile" = "host-partial" ] && [ "$command_name" = "diff" ]; then
  # Chezmoi flattens argv into CHEZMOI_ARGS. Stay below Linux's 128 KiB
  # per-string exec limit with enough headroom for the variable name and NUL.
  max_chezmoi_args_bytes=$((96 * 1024))
  diff_batch_args=()
  set_argument_byte_count "$chezmoi_bin"
  diff_batch_base_bytes=$argument_byte_count
  for diff_arg in "${chezmoi_args[@]}"; do
    set_argument_byte_count "$diff_arg"
    diff_batch_base_bytes=$((diff_batch_base_bytes + argument_byte_count + 1))
  done
  diff_batch_bytes=$diff_batch_base_bytes
```

**Before** — every surviving target appended to one invocation:

```bash
    if [ "$omit_target" -eq 0 ]; then
      chezmoi_args+=("$managed_target")
      included_target_count=$((included_target_count + 1))
    fi
```

**After** (`tests/helpers/chezmoi-unattended:232-247`) — accumulate, flush on budget, fail closed on an unsplittable target:

```bash
    if [ "$omit_target" -eq 0 ]; then
      set_argument_byte_count "$managed_target"
      target_bytes=$((argument_byte_count + 1))
      if [ "$((diff_batch_bytes + target_bytes))" -gt "$max_chezmoi_args_bytes" ]; then
        [ "${#diff_batch_args[@]}" -gt 0 ] || \
          fail "managed target is too long to invoke safely: $managed_target"
        "$chezmoi_bin" "${chezmoi_args[@]}" "${diff_batch_args[@]}" </dev/null
        diff_rc=$?
        [ "$diff_rc" -eq 0 ] || exit "$diff_rc"
        diff_batch_args=()
        diff_batch_bytes=$diff_batch_base_bytes
      fi
      diff_batch_args+=("$managed_target")
      diff_batch_bytes=$((diff_batch_bytes + target_bytes))
      included_target_count=$((included_target_count + 1))
    fi
```

Four properties are load-bearing:

1. **Budget below the limit, not at it.** 96 KiB against a 128 KiB limit leaves room for `CHEZMOI_ARGS=` plus its NUL terminator, and for whatever else the callee appends to its own argv before exec'ing.
2. **Count the fixed base once.** `diff_batch_base_bytes` covers the binary path plus the non-target flags, so every batch resets to a correct starting cost rather than zero (`tests/helpers/chezmoi-unattended:242`).
3. **Count bytes, not characters.** `set_argument_byte_count` (`tests/helpers/chezmoi-unattended:15-18`) sets `local LC_ALL=C` before `${#1}`, because the kernel limit is in bytes and a multibyte path would otherwise undercount.
4. **Fail closed on the unsplittable case.** If a *single* target exceeds the budget with an empty batch, there is no smaller invocation to make, so the launcher aborts rather than emitting a call it knows will fail (`tests/helpers/chezmoi-unattended:236-237`).

Batching preserves complete delivery: intermediate batches run immediately and propagate a non-zero exit, and the final partial batch is appended to `chezmoi_args` (`tests/helpers/chezmoi-unattended:253`) and consumed by the existing `exec` tail (`tests/helpers/chezmoi-unattended:264-267`), so the last invocation keeps the launcher's `exec`-based semantics.

Shipped in PR #177.

## Why This Works

Linux enforces two separate limits on `execve`:

- **`MAX_ARG_STRLEN`** caps any *single* argv or envp string. The Linux kernel defines it as `32 * PAGE_SIZE` in its own `binfmts.h` header, which is 128 KiB on the usual 4 KiB pages. It is a platform constant living in kernel source, not in this repository — nothing here defines or configures it, and there is no flag that raises it.
- **`ARG_MAX`** caps the *total* size of arguments plus environment. On modern Linux it derives from the stack rlimit, around 2 MB in practice, and `getconf ARG_MAX` reports this one.

Sizing a budget against `getconf ARG_MAX` gives roughly 16x more room than actually exists, and the failure still fires. The 464,434-byte `CHEZMOI_ARGS` was never close to the total limit; it was 3.5x over the per-string one.

The second half of the mechanism is why the diagnosis went wrong first. `E2BIG` is raised at the *next* `execve`, and once the oversized string is in the environment, every subsequent exec from that process inherits it. The oversized `chezmoi diff` invocation itself succeeded — it was launched by a shell whose environment was still small. The failure surfaced when chezmoi, now carrying its own 464 KB `CHEZMOI_ARGS`, tried to spawn a two-argument `herdr --version` from a template function. The error names the innocent bystander, and it names whichever subprocess happens to run first, so the same root cause can present as a different "failing binary" depending on template ordering.

## Prevention

**Read "argument list too long" as a claim about the environment, not the named binary.** When the message points at a command with obviously few, short arguments, stop reading that binary and start measuring the inherited environment entry by entry, looking for one oversized string rather than a large total. Measuring the total is what makes the wrong hypothesis survive.

**Bound the fan-out wherever this shape appears.** All three conditions held here, and they recur:

- The command line is built from a set whose cardinality the caller controls — glob expansion, `find` output, a `managed`/`ls-files`-style enumeration, a query result.
- The callee re-serializes its argv into a single-string channel: an environment variable, a config blob, a header. `CHEZMOI_ARGS` is one instance; any wrapper that re-exports its own invocation for child processes is another.
- The callee then spawns further subprocesses, so the oversized string is inherited by execs that have nothing to do with the large argument list.

Watch for it specifically with tools that advertise "pass targets explicitly to scope the operation" — that API invites unbounded fan-out. `xargs` solves the same problem when you own the pipeline; when the list is assembled inside a script, implement the same accumulate-and-flush discipline by hand.

**Treat an unbounded accumulator as a latent hard failure, not a present-day sizing question.** Nothing regressed here; the managed set crossed a fixed limit. The cap belongs in the code that constructs the list, not in a note about how many files the repo currently manages.

**Prove the split without weakening the assertion.** `test_chezmoi_unattended_0101_large_host_diff_stays_below_linux_exec_string_limit` (`tests/bashunit/chezmoi_unattended_test.sh:362-386`) drives a fake chezmoi that emits 2000 long managed targets on demand (`tests/bashunit/chezmoi_unattended_test.sh:32-40`), reconstructs the serialized argv the way chezmoi would, and exits non-zero past the simulated limit (`tests/bashunit/chezmoi_unattended_test.sh:53-61`):

```bash
  local linux_max_env_string_bytes=$((128 * 1024))
  local chezmoi_args_name_and_nul_bytes=14
  local max_chezmoi_args_bytes=$((linux_max_env_string_bytes - chezmoi_args_name_and_nul_bytes))
```

Each of its three assertions guards a distinct way the batching could be wrong:

- more than one `final` invocation was recorded — the split actually happened, so a budget silently raised out of relevance is caught;
- `cmp` of emitted against received targets — complete delivery, in order, nothing dropped or duplicated by the flush-and-reset;
- every recorded serialized-argv size stayed within budget — no batch crossed the line.

The oracle is Linux's own exec limit, expressed as a constant the fake enforces, plus delivery completeness expressed as byte-equality between what the enumerator produced and what the invocations received. Neither expected value is copied from the launcher, so refactoring the batching arithmetic cannot make the test pass vacuously.

**Platform caveat.** The 128 KiB figure is Linux-specific and the failure was only reproduced on Linux, inside the `make test-ubuntu` container. Whether Darwin imposes an equivalent per-string cap was not verified in this work — re-measure before relying on the number elsewhere.

## Related Issues

- PR #177, "fix(tests): batch oversized chezmoi diff arguments" — the change this document describes. Its source issue record was pruned once this document captured the lesson; the disproven `export -f` hypothesis it held is preserved in "What Didn't Work" above.
- `docs/solutions/design-patterns/outliving-processes-hang-the-suite.md` — sibling class: another harness defect that blocks the `make test-ubuntu` gate and names the wrong culprit, by process lifetime rather than exec-time argv size.
- `docs/solutions/test-failures/inherited-herdr-socket-contaminates-live-plugin-registry-2026-09-05.md` — the same subprocess boundary from the other side: which variables cross into a child, rather than how large one flattened variable may be. Note that `env -i` does not bound a variable the invoked tool synthesizes from its own argv.
- `docs/solutions/design-patterns/skip-set-parity-proves-reduced-dependencies.md` — the same proof obligation batching creates: a green run only counts if the complete target set was still delivered.
- `docs/solutions/design-patterns/semantic-regression-tests-over-source-shape.md` — the coverage-ownership rule this test obeys, using a controlled child process and filesystem markers as the oracle instead of inspecting the launcher's source.
