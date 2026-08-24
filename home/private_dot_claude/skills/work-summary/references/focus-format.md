# Focus Statement Format

The focus is the one sentence the coming period is measured against. It lives in the `current_focus` field of the user's workstream in vector-prime, and it is the top line of the next update. Writing one is a normal request — the user pastes a Slack thread, a customer situation, or a goal and asks what the focus should be.

## Shape

One sentence, sometimes two. Abstract in the first half, grounded in the second:

> Improve the platform's UI/UX, driven by data from K'Lani's real use.

The first half names the kind of improvement and outlives any single ticket. The second half says what makes this period different from the last one — a customer, a surface, a source of evidence. A focus that is only the first half could have been written any week; a focus that is only the second half is a task list.

Never write it as a list of deliverables. The focus states the direction; Linear holds the work.

## Rules

- **The previous focus is input to replace, not a preamble to keep.** `current_focus` usually carries a standing goal sentence plus a "this week is focused on…" sentence. Rewrite the period sentence and leave the standing one alone only if the user says the standing goal still holds. Re-emitting last period's sentence inside a new focus is the most common way to ship a stale one.
- **Say out loud what the focus depends on.** When it promises evidence that does not exist yet — session recordings from a customer who starts on Wednesday, a metric that is not instrumented — name that dependency in the conversation and offer a wording that survives the data not arriving. Do not bury the risk inside the sentence.
- **A new focus changes the next update.** It makes the update's closing line mandatory (`references/update-format.md` → Closing line), and the update's own focus line must be the old focus, not the new one — the update reports the period that just ended.
- **Verify the ground before writing.** A focus built from a Slack thread inherits that thread's claims. What is being launched, by whom, and when is worth one check against Linear or the product before it becomes the week's stated direction.

## When the user asks for options

Give **five variants with five different spines**, not one idea reworded. A spine is the angle the focus takes on the same period:

| Spine | What it makes the week about |
| --- | --- |
| Evidence over guesses | replacing assumptions with what real use shows |
| First contact | whether a newcomer can find and understand the thing unaided |
| Feedback loop | standing up the observation machinery and letting it set the agenda |
| Coherence | making separately built surfaces read as one product |
| Orientation | the user always knowing where they are and what to do next |

Label each variant with its spine so the user can pick an angle rather than compare wordings. The table is a starting set, not a fixed menu — the situation may have its own spines.

## Publishing

`PATCH /workstreams/<id>` with `current_focus` writes it. That field does **not** post to Slack — only updates do — but it is still an outward-facing write on a shared dashboard: draft it in the conversation, get an explicit go-ahead, then write. The field holds HTML: `<p>…</p>`, not markdown. Load the `vector-prime` skill for the call.
