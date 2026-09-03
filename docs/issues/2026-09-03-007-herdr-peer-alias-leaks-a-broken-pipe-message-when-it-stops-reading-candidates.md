---
title: "herdr-peer-alias leaks a broken-pipe message when it stops reading candidates"
short_description: "herdr-peer-alias read herdr_alias_candidates through a process substitution and exited at the first free alias, so with SIGPIPE inherited as ignored the producer took EPIPE and bash printed 1019 broken-pipe lines on the stderr the caller captured, which is how scripts_test 1401 failed on the CI macos runner while passing on a workstation where SIGPIPE has its default disposition; the script now reads the pool with one command substitution, which also stops discarding the producer's exit status."
type: "bug"
category: "testing-ci"
tags: ["flaky-test","herdr-aliases","epipe"]
date: "2026-09-03"
status: "done"
priority: "medium"
closed: "2026-09-03"
---

## Why this exists

`home/dot_local/bin/executable_herdr-peer-alias` read candidate aliases from a process
substitution and stopped at the first free one:

```
while IFS= read -r candidate; do
  if ! printf '%s\n' "$taken" | grep -qxF "$candidate"; then
    printf '%s\n' "$candidate"
    exit 0
  fi
done < <(herdr_alias_candidates "$seed")
```

`herdr_alias_candidates` (`home/dot_local/lib/herdr-aliases.sh:135-141`) emits all 1024
pool members in a loop, so the reader closed the pipe with about a thousand lines still
unwritten.

What happens next depends on the **inherited disposition of SIGPIPE**, not on the pipe
buffer:

- Default disposition: the producer subshell is killed by SIGPIPE and dies silently. This
  is a workstation shell, which is why the test always passed locally.
- Ignored disposition, inherited from whatever started the shell: `printf` gets EPIPE
  instead, and bash reports `printf: write error: Broken pipe` on the stderr it inherited
  from `herdr-peer-alias` — once per unwritten line.

Measured on 2026-09-03 with the pre-fix script, `trap '' PIPE` standing in for the
inherited disposition: **1019 broken-pipe lines**. With SIGPIPE at its default: silent,
across 20 runs.

`bashunit`'s `run` captures stderr into `$output`, so
`test_scripts_1401_herdr_peer_alias_skips_live_and_reserved_aliase` compared an alias
against an alias plus that line. CI run 33754209087, `test-macos`:

```
-- output does not match (exact) --
expected : ochre-bear
actual   : ochre-bear
.../home/dot_local/bin/../lib/herdr-aliases.sh: line 137: printf: write error: Broken pipe
```

The allocated alias was correct on both sides; only the leaked stderr differed.

The same construct hid a second defect. A process substitution discards its producer's
exit status, so a pool that failed `herdr_alias_validate_pool` reached the reader as zero
lines and was reported as `alias pool is exhausted` — a wrong diagnosis for a validation
failure.

## Scope

Read the pool once with a command substitution, then scan it from a here-string. No pipe
exists, so no writer can take EPIPE regardless of the inherited disposition, and the
producer's failure is now caught and reported as `could not build the alias pool`. The
empty-pool case keeps its previous meaning by falling through to the existing exhausted
branch instead of yielding an empty alias from `<<<`.

## Open decisions

None. The fix is in `herdr-peer-alias`, the reader that closes the pipe, because removing
the pipe also recovers the producer's exit status. `herdr_alias_candidates` has no other
caller that closes its output early.

## Resolution

herdr-peer-alias now reads the alias pool with one command substitution and scans it from a here-string, so no writer can take EPIPE regardless of the inherited SIGPIPE disposition, and a failed pool build is reported instead of being misdiagnosed as an exhausted pool. Negative control under an ignored SIGPIPE: the pre-fix script reproduces the CI failure exactly, including the broken-pipe line, and the post-fix script passes. tests/bashunit/scripts_test.sh reports 249 passed, 1 skipped, 0 failed. No test was added: a message assertion would copy its expected value out of the patched file, and the behavioural property was not deterministic before the fix, which is what made the original failure flaky.
