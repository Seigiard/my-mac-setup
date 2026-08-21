---
title: grc is vestigial — rgrc replaced it but was never moved cross-platform, and grc now survives only as the accidental python3 carrier
type: chore
date: 2026-08-21
status: open
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

1. Put `python3` in the Docker image by an honest route — `apt-get install -y python3` in
   `docker/Dockerfile.ubuntu`. It is a system tool, not a dotfile package. The CI runners
   already ship `python3`, and the `test-ubuntu` job cannot reach Linuxbrew at all
   (`docs/issues/2026-08-21-007-linuxbrew-prefix-unreachable-in-ubuntu-ci-job.md`), so this
   is the only environment that needs the change.
2. Delete `brew "grc"` from `Brewfile.tmpl`, along with the comment explaining why it was
   kept and the `grc` assertions in `tests/templates.bats`.
3. Decide `rgrc`'s home (below) and move it if the answer is cross-platform.

**Ordering.** Step 1 must land before step 2, or `python3` disappears from the Docker image
and 56 tests in `tests/palette.bats` start skipping silently — see
`docs/issues/2026-08-21-009-python3-is-both-required-and-optional-in-the-test-suite.md`,
which is the reason that failure would be confusing rather than obvious.

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
- Worth a broader inventory pass? The sweep that found this also showed several entries with
  no textual reference whose real consumer is yazi. A one-off audit could confirm each of
  those is genuinely reachable, but absence of a reference is weak evidence and the audit
  would mostly re-derive what the `# Yazi dependencies` heading already says.
