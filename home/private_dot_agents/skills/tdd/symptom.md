# Symptom

The bug branch of the tdd chain, reached from [Before the chain](SKILL.md#before-the-chain), step 1 of [The chain](SKILL.md#the-chain), and the **Not reproduced** row of [recovery.md](recovery.md#responding-to-a-failure). A ticket reports a bug when it carries the `bug` label or its text describes current behavior as wrong.

## The Symptom section

Add a `Symptom` section to `ticket.md` (layout in [run-directory.md](run-directory.md#ticketmd)): the observed behavior with the command or scenario the ticket gives, the expected behavior, and the criterion that covers it. Repeat the entry once per symptom criterion.

## Observation gate

A symptom criterion marked **no test**, at the oracle gate or later at lock acceptance, needs a recorded observation before any implementer starts: the command or scenario from `Symptom`, run on the production base, with its state and output recorded under `Symptom`. This applies per criterion, including in a ticket whose other criteria have locked tests.

- The observation shows the reported symptom: continue.
- It reaches the expected behavior under the recorded preconditions: the bug is **not reproduced** (below).
- Otherwise classify the incomplete observation in [recovery.md](recovery.md#responding-to-a-failure) before any implementation: an unrunnable command is **Prerequisite**, a missing scenario or expected result is **Decision**.

## Symptom-red

For a symptom criterion marked **test**, the lock's **Results** condition requires that the red run shows the symptom; red for another reason rejects the attempt. The test writer records the scenario and preconditions it established, the assertion the run reached, and whether the red output shows the symptom.

## Not reproduced

The bug is not reproduced when, during the initial investigation of a bug or of a new behavior gap, either holds:

- the symptom criterion's faithful test, accepted on every lock condition except **Results**, reaches the expected-behavior assertion and passes on `base_sha`;
- the observation reaches the expected behavior under the recorded preconditions.

Stop. Report the symptom, the test or command that sought it, and the observed behavior. The ticket may be stale, already fixed, or environment-specific; the caller decides. A suspect-test re-lock follows the existing re-lock and calibration rules instead.
