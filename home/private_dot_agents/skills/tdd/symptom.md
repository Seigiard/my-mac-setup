# Symptom

Add the `Symptom` section to `ticket.md` ([layout](run-directory.md#ticketmd)).

## Observation gate

A symptom criterion marked **no test**, at the oracle gate or later at lock acceptance, needs a recorded observation before any implementer starts: the command or scenario from `Symptom`, run on the production base, with its state and output recorded under `Symptom`. This applies per criterion, including in a ticket whose other criteria have locked tests.

- The observation shows the reported symptom: continue.
- It reaches the expected behavior under the recorded preconditions: the bug is **not reproduced** (below).
- Otherwise classify the incomplete observation in [recovery.md](recovery.md#responding-to-a-failure) before any implementation: an unrunnable command is **Prerequisite**, a missing scenario or expected result is **Decision**.

## Not reproduced

The bug is not reproduced when, during the initial investigation of a bug or of a new behavior gap, either holds:

- the symptom criterion's faithful test, accepted on every lock condition except **Results**, reaches the expected-behavior assertion and passes on `base_sha`;
- the observation reaches the expected behavior under the recorded preconditions.

Stop. Report the symptom, the test or command that sought it, and the observed behavior; the caller decides.
