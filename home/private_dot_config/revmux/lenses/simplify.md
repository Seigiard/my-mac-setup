---
description: "simplify — what the change could have left unwritten: a reinvented library, an unneeded dependency, a speculative abstraction, a diff bigger than its problem"
---
## Lens: simplify

Review the change for what should not have been written. The diff's best outcome is getting
shorter. `quality` judges how the code that stays is written; this lens asks whether each piece
needs to exist, and names what replaces it.

Put every unit the change adds — a function, a file, a dependency, an option, a layer — on the
first rung of this ladder that holds. The rung is the finding; a unit that reaches the bottom is
the new code the goal needed.

1. **nothing** (YAGNI): an abstraction with one implementation, a config nobody sets, a layer with
   one caller, an extension point nothing extends, a guard or fallback around a call that cannot
   fail that way, an option for a case the goal does not contain, a file the goal did not need
2. **the repository**: a helper, util or pattern already here does it. Run `rg` first and cite the
   copy; a helper that does not exist, or whose signature does not fit, is a finding the reader
   pays to disprove
3. **the standard library or runtime**: name the function
4. **the platform**: a native feature of the OS, shell, browser, framework or tool already in use.
   Name the feature
5. **an installed dependency**, over a new one
6. **one line**: the same logic in fewer lines with no loss of clarity. Show the shorter form
7. new code, the minimum that works

One move sits beside the ladder: a symptom patched at one caller where the shared function is the
cause. Grep every caller of what the change touches; one fix in the shared place is the smaller
diff, and it leaves no sibling broken.

A finding is one line of substance: location, what to cut, what replaces it, the lines it saves.
"This class might be more complex than necessary" is not one; "27-line validator class; `"@" in
email` is one line, real validation is the confirmation mail" is. A hand-rolled replacement that is
wrong on an input the library handles is a correctness defect: report it once and name `bugs`
beside this lens.

Done when every added unit sits on a rung. Report the units above rung 7 with the net lines they
would save; when every unit is at the bottom, say so and stop.

Leave alone:

- validation at a trust boundary, error handling that prevents data loss, a security check, an
  accessibility affordance, however much it looks like boilerplate
- anything the goal or the project's own rules ask for
- a deliberate simplification the code marks as such, with its ceiling and upgrade path named
- one small runnable check behind non-trivial logic: the minimum, not bloat
- clarity bought with lines: an early return over a nested ternary, a named intermediate over a
  dense one-liner
- the edge-case-correct form when two forms are the same size
