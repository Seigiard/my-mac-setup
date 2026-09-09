# Agent Verification

**Outcome:** collect the smallest evidence set that proves the affected behavior, then reuse each successful result while the state within its coverage remains unchanged.

## Select Evidence

Classify the changed paths before running checks. Deployment-sensitive classification takes precedence when a diff fits both rows.
Run the smallest canonical target or documented test command that proves the affected behavior; do not reconstruct its component commands.

| Risk class | Applies when | Required local evidence |
|---|---|---|
| Content-only managed file | An existing non-template managed file changes only in content | Applicable focused checks plus `make test-local`. Pull-request CI is the deployment backstop. |
| Checkout logic | A narrow test exercises changed logic directly from the checkout and the diff does not alter deployment behavior | The narrowest canonical focused check. Add `make test-local` only when the diff also contains a managed file. |
| Deployment-sensitive | A managed path is new, renamed, or removed; a `.tmpl`, `.chezmoiignore`, chezmoi run script under `home/.chezmoiscripts/`, or `.chezmoiexternal.toml` changes; or behavior depends on the deployed location | One successful `make test-ubuntu` verdict on the final deployment-relevant state before publishing. |

`make test-suite` reads the already-applied `~/` and applies nothing. It is evidence for deployed state, not for an unapplied checkout edit. `tests/bashunit/idempotent_test.sh` runs real chezmoi commands only when `MMS_DISPOSABLE_HOME=1`; `make test-ubuntu` supplies that disposable home.

A content-only managed-file verdict requires every existing canonical focused check whose coverage includes the change to pass. In `make test-local` output, confirm that the intended source content maps to the expected destination and that no path, template, or ignore behavior changed. When no focused test owns the content's semantics, report that missing local oracle and use the mandatory pull-request CI jobs for behavioral evidence; do not manufacture a source-shape test or upgrade a static content edit to deployment-sensitive solely because no focused test exists.

## Keep The Loop Tight

- Run checks after a coherent change batch.
- Use a focused suite for intermediate feedback or failure diagnosis. When the required broader suite includes it, do not run both as success gates against the same unchanged state.
- Reuse a passing result until files or generated state within its coverage change. Unrelated edits do not invalidate it.
- Before publishing, run only applicable checks that lack valid evidence for their current covered state.

## Finish With A Verdict

- A failed or incomplete required local check blocks publication until resolved.
- A diagnosed failed or interrupted attempt may be retried after its processes reach a terminal state.
- A skipped, partial, or isolated run is not a pass for a required broader check.
- When a required suite stalls, record the exact boundary, isolate the case, create a repository issue for unresolved behavior, and report the suite as incomplete.
- When CI is the backstop, report the risk class, substitute evidence, and why the broader local check adds no assurance.
- Both Ubuntu and macOS pull-request jobs must pass before merging.
