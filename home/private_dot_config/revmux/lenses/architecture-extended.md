---
description: "architecture supplement — establish compatibility consumers before recommending removal"
---
## Lens: architecture-extended

Before treating compatibility code as unused, check persisted data, public interfaces,
deployed clients, and dependent branches. An empty in-repo search is not proof that an
external contract is dead. Recommend removal only when evidence establishes that no
supported consumer still needs it.
