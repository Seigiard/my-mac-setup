# CE review rubrics compared with revmux

## Scope and sources

This is a rubric comparison, not a measured review-quality benchmark. The four
recommended improvements below are implemented in the managed source. The comparison
records the baseline before those edits; deployment remains a separate step.

## Implementation

- `simplify` now requires behavior equivalence and a concrete complexity benefit.
- `architecture` checks external and persisted consumers before removing compatibility.
- `efficiency` is a new lens on the existing lean agent. The profile still runs five
  agents, now carrying eleven code-review lenses between them.
- `adversarial` explicitly checks verification fidelity.
- `bugs` explicitly traces sentinel meanings and setup/cleanup exit paths.

The managed files live in `home/private_dot_config/revmux/`. `architecture`, `bugs`,
and `adversarial` are full overrides of the built-in lens text, with the additions
above. They replace those lenses in every profile that names them. Revisit these
overrides when upgrading revmux; upstream lens edits do not merge into local copies.

The managed `lean` and `final` profiles require supplied, current check results before
treating verification as successful. The local `final` override keeps the built-in
roster and severity bar; it replaces the unsupported claim that all checks already passed.

## Comparison baseline

Compared before the edits:

- Installed `ce-code-review`: `SKILL.md`, the persona catalog, and all 16 persona
  assets in `~/.agents/skills/ce-code-review/references/personas/`.
- Installed `ce-simplify-code`: `SKILL.md` and its code-reuse, code-quality, and
  efficiency reviewer assets. There is no separate selected `ce-simplify` skill.
- The eight built-in code-review lenses extracted from the installed revmux binary
  with `revmux --dump-defaults`: `bugs`, `impl`, `architecture`, `quality`, `docs`,
  `tests`, `comments`, and `adversarial`.
- The live user lenses `simplify` and `test-worth`, which match the managed sources
  in `home/private_dot_config/revmux/lenses/`.
- `revmux config`: the default `lean` profile runs five agents and includes all ten
  lenses above. The triage lenses are not part of this code-review roster.

The review protocol is separate from the rubrics. Scope preparation, execution,
synthesis, and verification remain revmux's job. The repository-owned `code-review`
skill owns the requested apply-and-repeat policy.

## Coverage map

“Covered” means the rubric already asks the question. “Partial” means a broad lens
can catch the defect but does not explicitly direct that line of investigation.

| CE rubric | Current revmux owner | Assessment |
|---|---|---|
| correctness | `bugs`, `impl` | Covered broadly; sentinel meanings and provisioning fidelity are more explicit in CE. |
| project-standards | `architecture`, `comments` | Covered: cite the applicable rule and its violation. CE adds path-specific standards discovery. |
| testing | `tests`, `test-worth`, `architecture` | Covered. The local oracle gate is stricter than CE's branch-count and missing-test heuristics. |
| maintainability | `quality`, `architecture`, `simplify` | Covered broadly. Named Fowler/Ousterhout smells add vocabulary, not a missing review phase. |
| agent-native | `impl`, `architecture` | Partial. Explicit action/context parity is absent; requiring agent integration in every product would be an unwanted new requirement. |
| learnings | `architecture` and round context | Partial. No explicit search of matching solution documents. `precedent` is a triage lens, not an active code-review lens. |
| security | `adversarial`, `bugs` | Partial. Trust-boundary attacks are covered, but authz, secrets, injection sinks, SSRF, and crypto have no dedicated checklist. |
| performance | `bugs`, `quality`, `simplify` | Partial. Resource failures are covered; N+1, hot-path allocations, blocking I/O, and bounded reads lack an explicit pass. |
| api-contract | `impl`, `bugs`, `architecture` | Partial. Caller changes are covered, but external clients and old payloads are not explicit. |
| data-migration | `bugs`, `impl`, `adversarial` | Partial. Mixed-version deployments, backfills, schema drift, and irreversible data loss have no migration-specific pass. |
| reliability | `bugs`, `adversarial` | Covered broadly. Retry budgets, cascading failures, and stand-in verification deserve more explicit triggers. |
| adversarial | `adversarial` | Covered broadly. CE explicitly attacks checks that go green while the real deployment fails. |
| previous-comments | prior-round injection and PR context | Partial. revmux history covers its own rounds, not necessarily GitHub review threads. |
| deployment-verification | round context and repository verification rules | No equivalent deployment checklist generator. That is operational planning, not a lens that must run on every change. |
| julik-frontend-races | `bugs`, `adversarial` | Partial. Resource lifetime and ordering are covered; effect early returns and DOM remounts are not explicit. |
| swift-ios | `bugs`, `quality`, `architecture` | Partial. No Swift-specific rubric for actor reentrancy, ownership wrappers, persistence contexts, or accessibility. |
| simplify: code reuse | `simplify`, `quality` | Covered. CE is more explicit about proving equivalent platform behavior before removing code. |
| simplify: code quality | `quality`, `simplify`, `architecture`, `docs` | Covered broadly. CE has stronger boundaries for dead-code claims and pre-release compatibility removal. |
| simplify: efficiency | `bugs`, `simplify` | Partial. Less code and less runtime work are different questions. |

## Recommended improvements

### 1. Put behavior equivalence before line savings

**Owners:** `simplify`; the compatibility bullet in `architecture`.

CE requires preserving outputs, errors, side effects, and ordering. It also requires
evidence before replacing serializers, coercions, or platform-managed behavior.
The current `simplify` lens leads with a shorter diff and asks for saved lines.
Its clarity and safety exceptions are useful, but do not establish equivalence.

Proposed rubric:

> Before recommending a replacement, establish equivalent outputs, errors, side
> effects, and ordering for the supported inputs. Name the provider of any platform
> guarantee being relied on. Check locale, sort stability, coercion, and serialization
> when those semantics change. Fewer lines alone is not a benefit.

The `architecture` lens also suggests removing compatibility code after in-repo
callers move. Add the missing boundary:

> Check persisted data, public interfaces, deployed clients, and dependent branches
> before declaring the old form unused. An empty in-repo search is not proof that an
> externally consumed contract is dead.

This is the highest-value transfer: it reduces unsafe simplification proposals
without adding another reviewer.

### 2. Add an efficiency rubric for actual runtime work

**Owner:** a small `efficiency` lens on the existing lean reviewer, with checks
conditional on the changed runtime path. No extra agent is needed.

Take the concrete checks from CE's efficiency and performance reviewers:

- duplicate reads, calls, and computations;
- N+1 work and unbounded fetches at an evidenced data size;
- blocking or repeated work on request, render, or startup paths;
- recurring updates that discard the platform's no-change signal;
- independent work serialized without a dependency that requires it;
- retained data, listeners, and subscriptions whose lifetime is not bounded.

Require a reachable path, expected workload, and concrete consequence. Avoid
speculative caching, blanket concurrency recommendations, and cold-path micro-tuning.
The benefit is distinct from the existing goal of reducing implementation complexity.

### 3. Make verification fidelity an explicit adversarial check

**Owner:** `adversarial`, conditional on changed CI, build, deploy, or test infrastructure.

The current lens contrasts tests with promises. CE goes further: construct a case
where the stand-in check passes while the real operation fails.

Proposed rubric:

> For a guard that stands in for another operation, compare their actual inputs,
> working directories, environment, prepared state, and command sequence. Name a
> concrete mismatch that lets the guard pass while the protected operation fails.

`test-worth` provides the detailed assertion-quality rubric. `adversarial` still
reports a concrete green-while-broken path when the selected profile has no
`test-worth` reviewer, including a false assertion that enables that path. Synthesis
deduplicates overlapping findings when both lenses are present.

### 4. Add two precise checks to bugs

**Owner:** `bugs`, conditional on the changed surface.

- When a sentinel gains a new meaning, trace consumers through rendering, metrics,
  and actions. Returning `[]` for both “empty” and “failed” can be wrong without a crash.
- For setup/cleanup changes, enumerate early returns and compare each mutation with
  its teardown. Include “already loaded” paths, cancellation, remounts, and late callbacks.

These refine existing responsibilities rather than introducing more agents. The
frontend-specific examples belong only on UI lifecycle changes.

## Useful only on matching work

These are real specializations, but do not justify expanding every default review:

- **Security:** add focused source-to-sink, ownership/authz, and secret-exposure checks
  when those boundaries change. Keep revmux's evidence-based severity calibration.
- **API and migrations:** review old clients against new responses, and old code
  against new schema/data. Check backfills, dual writes, and rollback only when
  persisted or external contracts exist.
- **Swift/iOS:** use a stack-specific rubric for Swift state ownership, actor
  reentrancy, persistence-context isolation, and accessibility. Generalize neither
  Swift API advice nor its severity examples to unrelated code.
- **Agent parity:** compare capabilities only when the product already promises
  agent access. Missing agent integration is not automatically a defect.
- **Learnings and previous comments:** improve round context with matching solution
  documents and unresolved PR feedback. This is context preparation, not another
  unconditional lens. Prior comments still need validation against current code.

## Keep as is

- Keep `test-worth` and the repository's independent-oracle gate. Do not import CE's
  rule that a missing test file or an uncovered branch alone proves a test gap.
- Keep revmux's severity bar. Do not import CE's severity escalation to retain
  uncertain security findings, or fixed file-length severity thresholds.
- Keep existing correctness, standards, documentation, and maintainability coverage.
  More copies of the same checks do not add independent scrutiny.
- Keep operational deployment checklists outside the default code-review lens set.
