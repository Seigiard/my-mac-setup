---
title: grc is vestigial — rgrc replaced it but was never moved cross-platform, and grc now survives only as the accidental python3 carrier
type: chore
date: 2026-08-21
status: done
closed: 2026-08-21
---

## Why this exists

`brew "grc"` in `home/private_dot_config/brewfiles/Brewfile.tmpl` is dead weight in every
environment, and the only reason it currently cannot be deleted is an accident.

**Nothing calls it.** The single colouriser initialisation in the shell is
`home/dot_zshrc.tmpl:108`:

```zsh
has rgrc && cached_init rgrc rgrc rgrc --aliases
```

That is `rgrc`, not `grc`. A word-boundary search for `grc` across the repository returns
no call site — no alias, no script, no config. The only hits are the Brewfile entry itself
and the tests that assert the entry exists.

**`rgrc` does not need it.** `brew info lazywalker/tap/rgrc` reports `dependencies: []`,
and its description is "Rusty Generic Colouriser - just like grc but fast". It is a
standalone replacement, not a wrapper that reuses grc's config files.

**`rgrc` was simply never moved.** It is declared only in
`home/private_dot_config/brewfiles/Brewfile.macos.tmpl:25`. So on Linux `has rgrc` is
always false and no command output is colourised at all — not a deliberate choice, just
the leftover of a replacement that stopped halfway (confirmed 2026-08-21).

**What keeps `grc` alive is a side effect.** `brew info grc` reports
`dependencies: ['python@3.14']`, and the Docker test image
(`docker/Dockerfile.ubuntu`) installs no `python3` of its own — its apt list is curl, git,
sudo, zsh, locales, ca-certificates, build-essential, procps, file. So `grc` is currently
the sole supplier of the `python3` that `tests/palette.bats` needs. That is why the
CI-minimal set keeps it, and the Brewfile carries a comment saying so.

That last paragraph describes the state that created this issue and is no longer current:
step 1 of Scope has landed, so the image installs its own `python3` and the Brewfile comment
no longer credits `grc` with supplying it. `grc` is now held in the file by this issue alone.

The cost is not theoretical: the timing measurement recorded in
`docs/plans/2026-08-20-2217-perf-ci-minimal-brew-install-plan.md` puts `grc` at **21 s** of
the Ubuntu install, against a minimal-set target of ≤ 35.6 s. A package nothing uses is
spending most of that budget.

Note the asymmetry that makes this different from other unreferenced entries. `ffmpeg`,
`poppler`, `resvg`, `sevenzip` and `imagemagick` are also unreferenced by name — but they
sit under `# Yazi dependencies` and yazi invokes them at preview time by built-in default,
so absence of a reference proves nothing there. `grc` is the only entry with *positive*
evidence of replacement: a named successor wired into the shell.

## Scope

1. **Done.** `docker/Dockerfile.ubuntu` installs `python3` in its apt layer, landed by
   `docs/plans/2026-08-21-0337-fix-python3-declared-dependency-plan.md` (R2/U1) rather than
   by the Dockerfile plan named under Sequencing below. `python3` is also now a stated
   system requirement in `README.md` with a 3.9 floor, and the bats suite asserts it instead
   of skipping on it. Measured in the rebuilt image before any `chezmoi apply`:
   `/usr/bin/python3` is **Python 3.12.3**, and the palette's own `--validate` exits 0 on it.
   This step is the precondition for step 2 — do not remove `grc` from a checkout where it
   is not present.
2. Delete `brew "grc"` from `Brewfile.tmpl`, along with the comment explaining why it was
   kept and the `grc` assertions in `tests/templates.bats`.
3. Decide `rgrc`'s home (below) and move it if the answer is cross-platform.

**Ordering.** Step 1 must land before step 2. It now has — but verify that before removing
`grc`, because the consequence changed rather than disappeared. The old failure mode was
silent: `python3` vanished and 56 tests in `tests/palette.bats` skipped without saying why.
That skip guard is gone (see
`docs/issues/2026-08-21-009-python3-is-both-required-and-optional-in-the-test-suite.md`), so
on a checkout without step 1 the same mistake now produces a named assertion failure naming
`python3` and pointing at the `README.md` requirements section. Loud instead of silent, but
still a broken image.

**Which interpreter the palette ends up on.** Removing `grc` removes `python@3.14` from the
image, so the palette drops from Homebrew's 3.14 to the apt interpreter that step 1
installs. Measured on the current `ubuntu:24.04` base, that is **3.12.3**, which still ships
`tomllib` in the standard library (stdlib since 3.11), so the palette keeps taking the
`tomllib` branch at
`home/private_dot_config/herdr/plugins/command-palette/palette.py:156-171` rather than its
own fallback parser. An earlier reading of this — 3.10.6, taking the fallback — was measured
against `ubuntu:22.04` and is stale: the base image moved to 24.04 in commit `f83e95d`.
What remains true either way is that **no test observes which parser ran**. The only
`tomllib` test forces the fallback by monkeypatching `builtins.__import__`, so an
interpreter change here is silent, and a future base-image move to something older than 3.11
would flip the branch with nothing reporting it.

**Sequencing against the plans.** `docker/Dockerfile.ubuntu` is owned by
`docs/plans/2026-08-20-2217-perf-docker-baked-brewfile-plan.md`, the next plan in the
settled landing order. Folding step 1 into that plan avoids a re-diff of the same file.
Note also that removing an entry changes the *full* Brewfile render, which the CI-minimal
change deliberately kept byte-identical — so this cannot be a silent tidy-up; it is a real
change to what a host installs. Existing machines keep their installed `grc` either way:
`brew bundle` does not uninstall what leaves the file.

## Open decisions

- Should `rgrc` move to the cross-platform `Brewfile.tmpl`, giving Linux the colourising it
  currently lacks? That depends on whether `lazywalker/tap` builds on Linuxbrew — unverified.
  If it does not, the honest outcome is that Linux has no colouriser and the macOS-only
  placement is correct after all.
- If `rgrc` does move, does it belong in the CI-minimal set? Almost certainly not — no test
  references it, and the shell init is guarded by `has rgrc`.
- Should a test observe which TOML parser the palette actually used, rather than only that
  the forced fallback works? Currently nothing does, so an interpreter change is invisible.
  Tracked here because `grc`'s removal is the change that makes it matter.
- Worth a broader inventory pass? The sweep that found this also showed several entries with
  no textual reference whose real consumer is yazi. A one-off audit could confirm each of
  those is genuinely reachable, but absence of a reference is weak evidence and the audit
  would mostly re-derive what the `# Yazi dependencies` heading already says.

## Resolution

Closed 2026-08-21. All three scope steps are done.

**Precondition verified before removal.** In this checkout, `docker/Dockerfile.ubuntu`
installs `python3` in its apt layer (line 30 of the `apt-get install` list), and
`README.md` states the `python3 >= 3.9` system requirement with the Linux note that
minimal images must `apt-get install -y python3`. Both checks passed before `grc` was
touched.

**Deleted.** `brew "grc"` and its keep-until-this-issue template comment left
`home/private_dot_config/brewfiles/Brewfile.tmpl`; the `assert_line --partial 'brew "grc"'`
pin and its explanatory comment left `assert_minimal_brewfile` in `tests/templates.bats`.
The stale Dockerfile comment crediting grc as the old python3 carrier was rewritten. A
word-boundary grep for `grc` (excluding `rgrc`) across `home/`, `tests/`, `docker/`,
`Makefile` and `.github` now returns nothing. Existing machines keep their installed grc —
`brew bundle` does not uninstall what leaves the file.

**rgrc moved cross-platform.** The open decision resolved in favour of the move:
`lazywalker/homebrew-tap/Formula/rgrc.rb` carries explicit `on_linux` blocks with prebuilt
binaries for both architectures (`rgrc-x86_64-unknown-linux-gnu.tar.gz`,
`rgrc-aarch64-unknown-linux-musl.tar.gz`), and both v0.6.20 release assets answer HTTP 200
on github.com — no compile, no dependency chain. `brew "lazywalker/tap/rgrc"` and its tap
moved from `empty_Brewfile.macos.tmpl` into `Brewfile.tmpl`, inside the `$full` guard: it
stays out of the CI-minimal set because no test references it and the shell init at
`home/dot_zshrc.tmpl:108` is guarded by `has rgrc`. `tests/templates.bats` now refutes rgrc
in the minimal render and pins it in the full render, mirroring the `brew "git"` pattern.

**Remaining open decisions.** The TOML-parser observability test is filed as
`docs/issues/2026-08-21-020-no-test-observes-which-toml-parser-the-palette-used.md` — grc's
removal is exactly the interpreter switch that made the gap real. The broader Brewfile
inventory audit is not filed: as this issue itself concluded, absence of a reference is
weak evidence and the audit would mostly re-derive what the `# Yazi dependencies` heading
already says.

Verified with `make test-templates` (39/39 pass, including all CI-minimal render-guard
tests) and `make lint` (clean).
