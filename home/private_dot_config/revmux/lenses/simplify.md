---
description: "simplify — what the change could have left unwritten: a reinvented library, an unneeded dependency, a speculative abstraction, a diff bigger than its problem"
---
## Lens: simplify

Review the change for code it does not need. Prefer fewer concepts and less duplication with the
same behavior. `quality` judges how the code that stays is written; this lens asks whether each
piece needs to exist, and names what replaces it.

Before recommending a removal or replacement, establish equivalent outputs, errors, side effects,
and ordering for the supported inputs. Name the provider of any platform guarantee being relied
on and show that it covers this path. Check locale, sort stability, coercion, and serialization
when those semantics are involved. A guard's removal can make a branch reachable; that branch is
not dead code. If equivalence is uncertain, leave the candidate out.

Put every unit the change adds — a function, a file, a dependency, an option, a layer — on the
first rung of this ladder that holds. A rung identifies a candidate, not a finding. Report it only
after establishing equivalent behavior and a concrete reduction in complexity.

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
6. new code, the minimum that works

One move sits beside the ladder: a symptom patched at one caller where the shared function is the
cause. Grep every caller of what the change touches; one fix in the shared place is the smaller
diff, and it leaves no sibling broken.

A finding names the location, what to cut, what replaces it, and why behavior stays equivalent.
Name the complexity removed, such as duplicated state or an unused layer; fewer lines alone is
not a benefit. Cite the existing implementation or provider contract that supports the replacement.
A hand-rolled replacement that is wrong on an input the library handles is a correctness defect:
report it once and name `bugs` beside this lens.

Done when every added unit has been assessed against the ladder and the equivalence requirement.
Report only behavior-preserving simplifications with a concrete benefit; if none qualify, say so
and stop.

Leave alone:

- validation at a trust boundary, error handling that prevents data loss, a security check, an
  accessibility affordance, however much it looks like boilerplate
- anything the goal or the project's own rules ask for
- a deliberate simplification the code marks as such, with its ceiling and upgrade path named
- one small runnable check behind non-trivial logic: the minimum, not bloat
- clarity bought with lines: an early return over a nested ternary, a named intermediate over a
  dense one-liner
- the edge-case-correct form when two forms are the same size
