# Project profile — my-mac-setup

This file carries **weights, not facts**. The diff in front of you is made of facts and you
can read them yourself; what you cannot read there is how much each one costs *here*.
Anything you could look up in the repository does not belong in this file. Everything below
is here because it changes a verdict.

## What is being built

A personal, reproducible dev-environment repository for macOS (primary) and Linux
(CI/Docker), managed by chezmoi. One maintainer. No runtime service, no users, no traffic,
no stored data, no uptime obligation, no downstream consumer whose API you must not break.
The product is a machine that comes up correctly from `chezmoi apply`, plus the agent
tooling layered on top of it.

The consequence, and it is the single largest correction to a default reviewer's prior:
scaling, availability, latency, observability, multi-tenancy, rate limiting, graceful
degradation under load and backwards compatibility for other callers carry **near-zero
weight here**. A finding built on any of them is noise no matter how sound it would be
elsewhere. The weight this repository actually has lives in the next section.

## What counts as damage

Ordered by what this repository has actually been burned by, not by abstract severity.

**A suite that hangs instead of failing.** Highest weight. A leaked background process, an
inherited file descriptor, an unbounded wait loop, a teardown racing a surviving writer — a
green-looking runner that never returns. Generic instinct rates this a medium tidiness
issue; here it is high, because the failure mode is not a red test, it is *no verdict at
all*, and it surfaces under `--jobs` or in Docker after passing focused on a workstation.
`docs/solutions/design-patterns/outliving-processes-hang-the-suite.md` carries
`severity: high` for exactly this class; read its `applies_when` before rating anything that
spawns, polls, or cleans up.

**A green test that cannot fail when the behavior is removed.** A source-shape assertion, a
rejection fixture with no valid control beside it, output asserted without first checking
exit status. The cost is not a weak test; it is a permanent false signal that makes every
later round trust a gate that never closes. Before endorsing *or* requesting a test, apply
the test-oracle gate in
`docs/solutions/design-patterns/semantic-regression-tests-over-source-shape.md`: it decides
whether a permanent test is warranted at all — zero new tests is a legitimate outcome — and
it requires the test to have been proven red against the regression. `CLAUDE.md` makes this
gate mandatory. A PR that adds a permanent test without it has skipped a required step.

**An edit that looks live but is not.** chezmoi splits every managed file into three copies:
this checkout (`home/…`), chezmoi's own separate clone (`~/.local/share/chezmoi/home/…`),
and the deployed file (`~/…`). Raw `chezmoi` reads the second, not the first. A diff can be
perfectly correct and still change nothing that runs. This is invisible in the diff by
construction, so weigh any claim of "verified working" against which copy was actually
exercised.

**A template that renders only on the author's machine.** An `onepasswordRead` not guarded by
`lookPath "op"`, a missing OS branch, an OS-specific managed path with no matching rule in
`home/.chezmoiignore`, a hardcoded secret. These pass locally and break the Linux/Docker
apply that every other verification depends on.

**A managed file edited at `~/` instead of at its source in `home/`.** The change works
until the next apply silently reverts it.

**Blast radius.** Nothing here serves traffic, so damage is never an outage. It is either
the maintainer's own machine failing to come up, or — more common and worse — verification
of *unrelated* work becoming impossible, because the only targets that apply the checkout
before asserting are the ones that just stopped returning.

## What counts as proof

`docs/agent-verification.md` is the authority on risk classes, evidence validity and the
publish and merge gates. Weigh a verification claim against it rather than against general
instinct. The specifics that most often decide whether a claim holds:

- `make test-ubuntu` and `make test-docker` are the only targets that **apply this checkout
  and then assert**. Deployment-sensitive changes — a new, renamed or removed managed path,
  a `.tmpl`, `.chezmoiignore`, `.chezmoiexternal.toml` or run script under
  `home/.chezmoiscripts/` — need one successful `make test-ubuntu` verdict on the final
  state before publishing. Nothing else substitutes.
- `make test-local` is a dry-run diff. It applies nothing.
- `make test-suite` reads the **already-applied** `~/`. It is evidence for deployed state,
  never for an unapplied checkout edit.
- `make lint` is shellcheck at `--severity=warning` plus `python3 scripts/check_bats_assertions.py tests`.
  Note that it deliberately excludes `tests/bashunit/*_test.sh` from shellcheck.
- **There is no typechecker.** Ten `*.test.ts` suites run under `bun test`; there is no
  `tsconfig.json`, no `package.json`, and no `tsc` invocation in the Makefile or in CI. A
  type error in TypeScript reaches `main` unchallenged. Do not assume a compiler caught it.

A "verified" claim naming a target that could not have proven the change is itself a
finding, and a high one — it converts an unverified change into an apparently verified one.

## What the norm looks like

Deliberate conventions, verified against the source. Reporting one of these as a defect is a
false positive:

- Tests are bashunit driven through the house DSL `tests/bashunit/test-dsl.bash`, which
  supplies a bats-compatible vocabulary (`run`, `assert_success`, `assert_output --partial`,
  `skip`, the `BATS_*` contract, `_bats_file_init` / `_bats_test_init`). Not stock bashunit,
  not bats. See `docs/decisions/0011-retain-bashunit-with-a-bats-compatible-vocabulary.md`.
  An assertion name absent from upstream bashunit is not a bug.
- Test functions carry generated names of the form `test_<suite>_<NNN>_<truncated phrase>`,
  with the readable title passed to `_bats_test_init`. The truncation is mechanical.
- Shell must stay **Bash 3.2-compatible** (macOS `/bin/bash`): no `declare -A`, no
  `readarray`, no `${var^^}`. Code avoiding a modern builtin is meeting a constraint, not
  written by someone who did not know it existed.
- `modify_` scripts (`home/modify_dot_claude.json`, `home/dot_pi/agent/modify_settings.json`)
  read the existing file on stdin and emit a replacement. They are not templates and do not
  follow template rules.
- Filenames under `home/` encode chezmoi semantics — `private_`, `dot_`, `executable_`,
  `run_once_`, `.tmpl`. They are not typos or inconsistent naming.
- TypeScript tests use `// #given` / `// #when` / `// #then` phase markers. Required
  structure, never stray commentary. Ordinary explanatory comments, by contrast, earn their
  place only by saying something the code cannot.

## The reporting bar

A finding must be material, not merely true. One maintainer reads every round; noise is what
makes rounds stop being read, so a false positive costs more here than a missed nit.

Do not report: style and formatting preference; a restatement of what the diff already
shows; "add a test" where the test-oracle gate says zero new tests is the right answer;
production-service advice from the first section; any convention listed above; anything
shellcheck or `check_bats_assertions.py` already catches, since it will be caught without
you.

Do report, every time: a deviation from a rule this repository has written down. A
documented rule broken is always material, even when the immediate consequence looks small —
the rules exist because the consequence already happened once.

## Where the rules live

- `CLAUDE.md` — the `<important if>` blocks: where new things go, the chezmoi three-copy
  split, secrets and 1Password guards, the test-oracle gate, which `make` target proves what.
- `docs/agent-verification.md` — risk classes, evidence validity, publish and merge gates.
- `docs/solutions/` — this repository's own post-mortems, with YAML front matter carrying
  `severity` and `applies_when`. Nineteen of them. When a change falls inside an
  `applies_when`, that document sets the severity, not your general instinct.
- `docs/decisions/` — ADRs for costly-to-reverse choices.
- `CONCEPTS.md` — domain vocabulary.
