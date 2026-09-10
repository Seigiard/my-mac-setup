---
title: Role-Based SSH Access - Plan
type: feat
date: 2026-09-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
deepened: 2026-09-09
simplified: 2026-09-09
---

# Role-Based SSH Access - Plan

## Goal Capsule

- **Objective:** Either laptop can reach the other laptop and the home server through stable SSH aliases. The server can authenticate SSH Git operations through a temporary forwarded laptop agent without storing an outbound private key.
- **Means:** Bind one machine role at `chezmoi init`, render SSH client and inbound authorization files from shared data, and use each laptop's 1Password SSH key for managed aliases.
- **Stop conditions:** Stop before a first apply if an existing inbound key or required SSH stanza has not been copied into the new policy, if a laptop public key does not match its 1Password item, or if no current session, local console, or readable backup can recover the destination.
- **Execution profile:** One deployment-sensitive implementation followed by a manual three-machine rollout. Preserve existing access until the new path works from a fresh session.
- **Tail ownership:** The implementer owns source changes and automated verification. The user owns real-machine applies, 1Password approval, host-key confirmation, and live SSH checks.

---

## Product Contract

### Summary

Chezmoi manages one role-aware SSH policy for `mbp2021`, `mbp2026`, and `server`. Each laptop uses its own 1Password key to reach the other laptop and server. The server keeps no persistent outbound private key; an explicit agent-forwarded session supplies temporary Git authentication.

### Requirements

**Roles and shared data**

- R1. An installation stores exactly one role from `mbp2021`, `mbp2026`, or `server` during `chezmoi init` or its first apply; later applies use the stored value rather than a hostname or changed environment variable.
- R2. One committed data file maps roles to SSH aliases, Tailscale MagicDNS hostnames, Unix users, laptop public-key files, 1Password item selectors, and complete inbound authorization lines.
- R3. An interactive apply with no stored role asks once and persists the answer beside the chezmoi config. A non-interactive apply requires `MMS_MACHINE_ROLE`. An unknown role or unsupported role and operating-system combination fails before changing an SSH file.

**Authentication policy**

- R4. Each laptop offers only its own 1Password-backed identity to managed machine aliases and stores no managed private key under `~/.ssh`.
- R5. `mbp2026` authorizes `mbp2021`, `mbp2021` authorizes `mbp2026`, and `server` authorizes both laptops plus every existing recovery key deliberately retained during adoption.
- R6. The server stores no persistent outbound private key. Its client policy uses `IdentityFile none`, `IdentitiesOnly no`, and the current `SSH_AUTH_SOCK` so a forwarded agent remains usable.
- R7. Agent forwarding is disabled by default and enabled only by an explicit non-multiplexed session for temporary Git work on the trusted server.
- R8. No private key, decrypted key, private-key fixture, or 1Password secret enters the repository, rendered output, or test logs.

**Rollout**

- R9. Before chezmoi first replaces a destination's `authorized_keys`, the operator creates a readable local backup and keeps an existing session or local console available until a fresh login succeeds.
- R10. Live acceptance covers both laptop-to-laptop paths, both laptop-to-server paths, a normal server session without a forwarded agent, and one explicit forwarded server session that completes a Git operation through an existing SSH remote.

### Key Decisions

- **Chezmoi remains the single owner of retained SSH policy** (session-settled: user-directed - chosen over maintaining three independent SSH configurations). Existing keys and stanzas are inventoried once before adoption, then the managed files become authoritative.
- **The server has no persistent outbound private key** (session-settled: user-directed - chosen over provisioning a permanent server identity). Temporary Git authentication comes from a laptop agent.
- **Explicit whole-agent forwarding is accepted on the trusted server** (session-settled: user-directed - chosen over a persistent server credential). The server may request signatures from any identity exposed by the forwarded 1Password agent until the dedicated session ends.

### Acceptance Examples

- AE1. Given a pre-feature configuration with no `machine_role`, the first apply selects and persists a role before changing SSH files; a later apply reuses that role without prompting.
- AE2. Given either laptop role, a fresh connection to a managed destination offers that laptop's public identity and the destination accepts it.
- AE3. A normal server session has no forwarded agent. A session opened with `ssh -o ControlMaster=no -o ControlPath=none -A server` can run a Git operation against the repository's existing SSH remote, and a later normal session cannot use that agent.

### Scope Boundaries

- In scope: role binding, SSH aliases, 1Password agent selection, public-key authorization, preservation of existing access, temporary Git forwarding, and a short attended rollout.
- Out of scope: enabling SSH daemons, changing password authentication, managing Tailscale grants or firewalls, managing `known_hosts`, operating an SSH certificate authority, and automating the real-machine rollout.
- Tailscale resolution, port 22 reachability, working SSH daemons, and physical or console recovery are prerequisites.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Persist `machine_role` at initialization or first apply.** Interactive init offers the three supported roles. If an older config has no role, source-state resolution reads `~/.config/chezmoi/machine-role`, then `MMS_MACHINE_ROLE`, then prompts through the controlling terminal. The first resolved value is persisted and later rendering ignores environment changes. An invalid explicit role fails.
- KTD2. **Keep endpoint and authorization data in `home/.chezmoidata/ssh.yaml`; keep laptop public keys as plain `.pub` source files.** Public keys and 1Password item IDs are non-secret. Authorization entries store complete lines so retained options are not lost.
- KTD3. **Render one client template with a small role matrix.** Laptop roles use the documented 1Password socket, their own public key as `IdentityFile`, `IdentitiesOnly yes`, and `ForwardAgent no`. The server uses `IdentityFile none`, `IdentitiesOnly no`, no persistent `IdentityAgent`, and `ForwardAgent no`.
- KTD4. **Render one complete 1Password `agent.toml` per laptop role.** Preserve selectors used by existing Git, SSH, signing, and graphical clients. The server does not manage this file.
- KTD5. **Use real consumers as the oracle.** OpenSSH parses rendered client config, chezmoi proves role persistence and deployment, the real 1Password agent proves selector behavior, and fresh SSH sessions prove authentication. Tests do not duplicate 1Password or SSH daemon semantics.

### Assumptions

- `mbp2021` and `mbp2026` run macOS; `server` runs Linux.
- Tailscale MagicDNS and the intended port 22 paths already work.
- Each laptop has a distinct Ed25519 key in 1Password or will create one before rollout.
- The operator can inspect current SSH files on all three machines and has physical or console access to the home server.
- The server is trusted during the explicit forwarded session. Forwarding ends when that non-multiplexed session closes.
- The server can update this public repository over HTTPS without an SSH credential.

### Output Structure

```text
home/
|-- .chezmoidata/
|   `-- ssh.yaml
|-- private_dot_ssh/
|   |-- private_config.tmpl
|   |-- private_authorized_keys.tmpl
|   |-- mbp2021.pub
|   `-- mbp2026.pub
`-- private_dot_config/
    `-- 1Password/
        `-- private_ssh/
            `-- private_agent.toml.tmpl
```

The deployed targets are `~/.ssh/config`, `~/.ssh/authorized_keys`, the public-key files, and, on laptop roles only, `~/.config/1Password/ssh/agent.toml`. Public-key files may exist on every role because they contain no secret material.

### Sequencing

1. Add role data and prove first-apply role persistence before managing any new SSH target.
2. Add client, authorization, and agent templates with focused render tests.
3. During rollout, install authorization on all destinations before activating laptop client identities.
4. Keep old access until the live matrix and one post-restart check pass.

---

## Implementation Units

### U1. Role and SSH data

- **Goal:** Establish the three roles, shared endpoint data, and one-time selection for existing role-less installations.
- **Requirements:** R1-R3, R8. Implements KTD1 and KTD2.
- **Files:**
  - `home/.chezmoi.yaml.tmpl`
  - `home/.chezmoidata/ssh.yaml` (new)
  - `home/.chezmoiignore`
  - `.github/workflows/test-dotfiles.yml`
  - `docker/docker-compose.yml`
  - `tests/helpers/common.bash`
  - `tests/bashunit/templates_test.sh`
- **Approach:**
  1. Read and validate `MMS_MACHINE_ROLE` during init. Resolve and persist a missing role before apply builds SSH targets.
  2. Add the three role records and the inbound authorization lists without private material.
  3. Prompt through the controlling terminal when no role source exists. Reject invalid role and operating-system combinations.
  4. Use `server` for Ubuntu and Docker unattended paths and `mbp2026` for macOS CI. Render all role branches in focused tests.
- **Test scenarios:**
  - Each supported role renders, and unattended initialization does not prompt.
  - A role-less existing config resolves a role, manages planted SSH sentinel files, and reuses the persisted role.
  - An invalid or unsupported role fails before changing planted SSH sentinel files.
- **Verification:** Supported roles render. First apply persists its role. Invalid roles fail without partial SSH writes.

### U2. SSH and 1Password templates

- **Goal:** Render the outbound identity policy and complete inbound key matrix.
- **Requirements:** R4-R8. Implements KTD2-KTD5.
- **Dependencies:** U1 and a one-time manual inventory of current SSH config, `authorized_keys`, and `agent.toml` content.
- **Files:**
  - `home/.chezmoidata/ssh.yaml`
  - `home/private_dot_ssh/private_config.tmpl` (new)
  - `home/private_dot_ssh/private_authorized_keys.tmpl` (new)
  - `home/private_dot_ssh/mbp2021.pub` (new)
  - `home/private_dot_ssh/mbp2026.pub` (new)
  - `home/private_dot_config/1Password/private_ssh/private_agent.toml.tmpl` (new)
  - `home/.chezmoiignore`
  - `docker/Dockerfile.ubuntu`
  - `tests/bashunit/templates_test.sh`
  - `tests/bashunit/idempotent_test.sh`
- **Approach:**
  1. Export or create one laptop public key from each 1Password item and commit only the `.pub` values.
  2. Copy every retained client stanza, inbound public key, authorization option, and 1Password selector into the managed inputs.
  3. Render the role matrix from KTD3 and the inbound matrix from R5. Never produce a zero-key `authorized_keys` for a supported role.
  4. Render the complete laptop agent allowlist and omit `agent.toml` on the server.
  5. Install `openssh-client` explicitly in the Ubuntu test image because focused tests invoke `ssh -G` and `ssh-keygen` before apply.
- **Test scenarios:**
  - `ssh -G` resolves each managed laptop alias to the intended host, user, 1Password socket, single public identity, `IdentitiesOnly yes`, and `ForwardAgent no`.
  - The server config resolves to `IdentityFile none`, `IdentitiesOnly no`, no persistent `IdentityAgent`, and `ForwardAgent no`.
  - Each rendered `authorized_keys` matches R5 plus the manually retained lines; malformed, duplicate, and zero-key results fail.
  - The laptop agent allowlist contains the role selector plus all retained selectors; server and Linux paths do not manage it.
  - Both public keys parse with `ssh-keygen`, differ, and match their attended 1Password fingerprints.
  - Applying the same role twice in a disposable home leaves managed SSH files unchanged.
- **Verification:** Focused render tests, idempotency, and the Ubuntu deployment pass. Real 1Password behavior remains an attended laptop check.

### U3. Manual rollout and live acceptance

- **Goal:** Adopt the policy without losing current access and prove ordinary and forwarded Git paths.
- **Requirements:** R4-R10. Uses KTD3-KTD5.
- **Dependencies:** U1-U2, working SSH daemons and Tailscale paths, and local or console recovery.
- **Files:**
  - `README.md`
- **Approach:**
  1. Document role initialization, required 1Password item IDs, exact target-scoped commands, and the six live checks from R10.
  2. On every machine, back up `~/.ssh/authorized_keys` and any managed SSH or agent file that already exists. Confirm each backup is readable.
  3. Keep an existing server session open. Apply only the managed `authorized_keys` target on `server`, then each laptop. Verify a fresh login after each destination change.
  4. After all destinations accept the new public keys, apply the full role on each laptop. Check `ssh-add -L`, the relevant `ssh -G` output, and one fresh connection before continuing.
  5. Run both laptop-to-laptop connections, both laptop-to-server connections, a normal server session with no forwarded agent, and `ssh -o ControlMaster=no -o ControlPath=none -A server` followed by a Git operation against an existing repository's SSH remote.
  6. Compare each destination host-key fingerprint once through its local console before first acceptance. `known_hosts` remains operator-managed.
  7. Restart each laptop, unlock 1Password, and verify one fresh managed login. Then manually remove obsolete local private-key files and the temporary backups.
- **Execution note:** The user performs every host apply. An agent must never run `chezmoi apply` on the host.
- **Verification:** The six-path matrix passes, the forwarded capability disappears with its dedicated session, one post-restart login succeeds from each laptop, and the server has no persistent outbound private key.

---

## Risks & Dependencies

- **Lockout during first adoption:** Preserve current authorization lines, make readable backups, keep an existing session open, and use the local console if a fresh login fails.
- **Wrong 1Password item:** Compare each committed public key with `ssh-add -L` and the item's displayed fingerprint before rollout.
- **Existing consumers lose agent keys:** Preserve current `agent.toml` selectors before chezmoi takes ownership.
- **Forwarded-agent abuse:** The trusted server can request signatures from every exposed agent identity during the explicit session. Keep forwarding off by default, disable multiplexing for that session, and close it immediately after Git work.
- **Both laptop agents are unavailable:** Recovery uses the server's physical or local console. An additional offline recovery key is optional and can be added as another retained public authorization line.
- **External prerequisites drift:** Tailscale, firewall, and daemon failures are diagnosed separately from rendered SSH policy.

---

## Verification Contract

| Check | Command | Gate |
|---|---|---|
| Focused SSH templates | `tests/lib/bashunit -j 8 tests/bashunit/templates_test.sh tests/bashunit/idempotent_test.sh` | Required after template or test changes |
| Shell lint | `make lint` | Required when shell helpers change |
| Checkout-to-home diff | `make test-local` | Required before user deployment; never applies changes |
| Disposable Ubuntu apply | `make test-ubuntu` | Required on the final deployment-sensitive state |
| Repository secret scan | `gitleaks dir --no-banner --redact --exit-code 2 .` | Required before publication |
| Real laptop identity | `ssh-add -L` plus fingerprint comparison | Required on both laptops |
| Live SSH matrix | Fresh non-multiplexed SSH sessions for R10 | Required before deleting old access |

Before the first test edit, the implementation workflow must state KTD5's oracle line: the consumer is OpenSSH or chezmoi, the observable failure is incorrect identity selection or deployment, and the independent oracle is real consumer output rather than template literals or the data changed by the patch.

---

## Definition of Done

- R1-R10 hold in the repository and on the three real machines.
- A role-less configuration resolves and persists its role before SSH files change; invalid roles fail before changing them.
- Both laptop public keys match their 1Password items, and no private key appears in the repository or rendered output.
- Each destination retains the intended inbound keys and accepts the required laptop identity from a fresh session.
- The ordinary server session has no forwarded agent. The explicit non-multiplexed session completes a Git operation and loses agent access at logout.
- `make test-ubuntu`, applicable focused checks, and the repository secret scan pass.
- Each laptop succeeds once after restart and 1Password unlock before obsolete local keys and temporary backups are removed.
- `README.md` contains the short rollout and recovery procedure.

---

## Appendix

### Sources

- 1Password SSH Agent: https://developer.1password.com/docs/ssh/agent
- 1Password SSH Agent configuration: https://developer.1password.com/docs/ssh/agent/config
- 1Password agent forwarding: https://developer.1password.com/docs/ssh/agent/forwarding
- OpenSSH client configuration: https://man.openbsd.org/ssh_config
- Chezmoi target types: https://chezmoi.io/reference/target-types/
- Repository verification policy: `docs/agent-verification.md`
- Semantic test ownership: `docs/solutions/design-patterns/semantic-regression-tests-over-source-shape.md`
