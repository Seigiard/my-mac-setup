---
description: "adversarial supplement — checks that pass while the operation they protect fails"
---
## Lens: adversarial-extended

When the change touches CI, build, deploy, or test infrastructure, compare the check with
the operation it protects: inputs, working directories, environment, prepared state, and
command sequence. Construct a reachable case where the check passes but the real operation
fails, and cite the mismatch that permits it. A harmless environmental difference is not
a finding. This check applies regardless of diff size.

Include a false assertion when it creates such a green-while-broken path. Report the
demonstrated failure even if another lens could also find it; synthesis owns deduplication.
