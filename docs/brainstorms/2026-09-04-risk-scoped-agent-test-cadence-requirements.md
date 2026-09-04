---
date: 2026-09-04
topic: risk-scoped-agent-test-cadence
---

# Risk-Scoped Agent Test Cadence

## Summary

Repository guidance will select tests by deployment risk and prevent agents from rerunning successful checks while the state covered by those checks remains unchanged. Content-only managed-file changes will rely on focused local evidence plus pull-request CI, while deployment-sensitive changes retain one final local Docker gate before publishing.

---

## Problem Frame

Agents currently interpret any edit under `home/` as requiring `make test-ubuntu`. Several individually reasonable instructions combine into an unconditional pre-push gate, so even changes whose behavior is exercised directly from the checkout trigger a full Docker build, disposable-home apply, and complete suite. Repeated runs add minutes of latency, consume a visible Herdr pane, and require supervision without adding evidence when the relevant files have not changed.

---

## Actors

- A1. Coding agent: selects and runs checks while implementing and publishing a change.
- A2. Pull-request CI: supplies the cross-platform deployment backstop after a branch is pushed.

---

## Requirements

**Risk selection**

- R1. The coding agent must classify the changed paths by deployment risk before selecting checks.
- R2. A content-only edit to an existing non-template managed file must not require a local `make test-ubuntu` run when every applicable canonical focused check passes and `make test-local` confirms the intended destination mapping without path, template, or ignore changes. When no focused test owns the content semantics, the agent must report the missing local oracle and use pull-request CI as the behavioral backstop.
- R3. Logic exercised directly from the checkout must use its narrowest canonical test rather than a full deployment suite unless the same diff also changes deployment behavior. `make test-local` applies only when that diff includes a managed file.
- R4. Changes that can alter deployment behavior must retain a local `make test-ubuntu` gate before publishing. This class includes new, renamed, or removed managed paths; templates; ignore rules; chezmoi run scripts under `home/.chezmoiscripts/`; externals; and changes whose behavior depends on the deployed location. This classification takes precedence over the content-only class.

**Cadence and evidence**

- R5. During implementation, the coding agent must use focused checks after a coherent change batch when they provide intermediate feedback or diagnose a failure, not after each individual edit or immediately before an encompassing final suite on the same diff.
- R6. A successful check must not be repeated while the files or generated state covered by that check remain unchanged.
- R7. For a deployment-sensitive diff, the coding agent must obtain one successful `make test-ubuntu` verdict on the final deployment-relevant state before publishing and must not repeat that successful check while the state within its coverage remains unchanged. A diagnosed failed or interrupted attempt may be retried after its processes reach a terminal state.
- R8. The coding agent must not run both a narrower suite and a broader suite containing the same coverage against the same unchanged diff unless the narrower result is needed to diagnose a failure.
- R9. Before publishing, the coding agent must run only applicable checks without valid evidence for the current files and generated state within each check's coverage. Unrelated changes outside that coverage must not invalidate existing evidence.
- R10. When skipping a broad check, the coding agent must report the selected risk class, the evidence used instead, and the reason the broader check adds no pre-push assurance.

**CI boundary**

- R11. Existing Ubuntu and macOS pull-request checks remain unchanged and mandatory as the deployment backstop for content-only changes.
- R12. A failed or incomplete required local check remains blocking; this policy changes check selection and cadence, not how failures are treated.

---

## Acceptance Examples

- AE1. **Covers R1, R2, R9, R10, R11.** Given a value-only edit to an existing non-template configuration file, when the agent prepares to publish, it runs applicable focused checks and `make test-local`, skips local `make test-ubuntu` with a stated reason, and relies on pull-request CI for full deployment coverage.
- AE2. **Covers R1, R3, R5.** Given an executable managed script with a canonical test that reads the script from the checkout, when its logic changes, the agent runs that focused test after the coherent edit batch rather than running the full Docker suite after each edit.
- AE3. **Covers R1, R4, R7.** Given a template or managed-path change, when the deployment-relevant state is ready to publish, the agent obtains one successful `make test-ubuntu` verdict and does not repeat it while the state covered by that check remains unchanged.
- AE4. **Covers R6, R9.** Given a focused test that passed and no covered file changed afterward, when the agent reaches the pre-publish step, it reuses the existing result instead of rerunning the test.
- AE5. **Covers R6, R7, R9.** Given a required check that passed and a later edit changes a file within that check's coverage, when the agent prepares to publish, the previous result is no longer valid and the agent reruns the check.
- AE6. **Covers R8.** Given a broad suite that includes a narrower template suite, when the broad suite passes against the same diff, the agent does not run the narrower suite as an additional success gate.
- AE7. **Covers R12.** Given a selected required check that fails or cannot reach a verdict, when the agent prepares to publish, it reports the incomplete evidence and does not reinterpret the new policy as permission to ignore the result.
- AE8. **Covers R7, R12.** Given a required Docker attempt that fails or is interrupted, when its processes have reached a terminal state and the cause has been addressed, the agent may retry it to obtain the required successful verdict.
- AE9. **Covers R6, R9.** Given a focused test that passed, when an unrelated documentation file outside that test's coverage changes, the focused result remains valid and is not rerun before publishing.

---

## Success Criteria

- Content-only edits to existing non-template managed files no longer trigger local full Docker runs by default.
- Deployment-sensitive changes still receive one local disposable-home verification before publishing.
- Agents do not rerun successful checks when the diff relevant to those checks is unchanged.
- Agent reports make the selected risk class and omitted checks auditable.
- A downstream implementer can update the repository guidance without inventing additional policy decisions.

---

## Scope Boundaries

- Do not add an automatic changed-path test selector in this iteration.
- Do not add a new fast disposable-home test target in this iteration.
- Do not restructure the test suites or change their coverage in this iteration.
- Do not weaken, remove, or conditionally skip existing pull-request CI jobs.
- Do not allow failed or incomplete required checks to become non-blocking.

---

## Key Decisions

- Pull-request CI is an acceptable deployment backstop for content-only edits to existing non-template managed files.
- The first iteration changes repository guidance and agent cadence only.
- Deployment-sensitive changes require one successful full local Docker verdict on the final deployment-relevant state before publishing.
- Check evidence is invalidated by changes within its coverage, not by unrelated edits or the passage from implementation to publishing.
