---
title: Deliver machine secrets with age and per-machine identities
status: accepted
date: 2026-10-07
supersedes: []
---

# ADR-0023: Deliver machine secrets with age and per-machine identities

## Context

Until now 1Password delivered two kinds of machine secrets: API keys, read by
`onepasswordRead` while chezmoi rendered `~/.zshenv`, and SSH private keys,
served per use by the 1Password SSH agent. Both ask for approval on the screen
of the machine where the read happens. Working on one laptop over SSH from the
other, that screen is out of reach, so `chezmoi apply` and every `ssh` or
`git` call over SSH stalled on a prompt nobody could answer. The
`gh`-credential workaround in `dot_gitconfig.tmpl` and the unattended profiles
of ADR-0006 were earlier symptoms of the same constraint.

## Considered options

- **fnox or sops with age.** Both add a runtime that injects secrets per
  process. The repository needs the keys in every shell, hook, and agent, not
  per project, and neither tool covers SSH keys.
- **macOS Keychain.** No sync between laptops, nothing for the Linux server,
  and the login keychain is locked in an SSH session without a GUI login,
  which is the exact situation to fix.
- **1Password service account.** Rejected for unattended use in ADR-0006, and
  a service account cannot read the Private vault that holds these items.
- **Agent forwarding from the laptop in use.** Already the server's model
  (ADR-0004). It covers SSH only while the session is attended, and leaves the
  template reads unsolved.
- **chezmoi's built-in age encryption.** Ciphertext in the source tree,
  decrypted at apply with a local key, no prompt, no new runtime, and the same
  `git pull` / `chezmoi apply` path the rest of the machine already uses.

## Decision

Machine secrets travel in the source tree as one age-encrypted YAML file and
reach `~/.zshenv` through chezmoi's `decrypt` at apply. Each laptop generates
its own age identity, which never leaves it; the public half is the
`age_recipient` of the laptop's role in `machines.yaml`, and the file is
encrypted for every enrolled recipient. Enrollment and revocation are a
recipient edit plus a re-encryption from an already enrolled laptop.

Where no identity exists (server, CI, Docker, a laptop before enrollment) the
decrypted target is ignored and the shell renders without keys. Where an
identity exists but cannot decrypt the file, apply fails rather than rendering
a key-less shell.

SSH private keys leave 1Password and sit on their own laptop at
`~/.ssh/<role>`, without a passphrase, never committed. chezmoi keeps managing
the public keys and the `authorized_keys` matrix. The server stays keyless and
secret-less. GitHub HTTPS remotes keep the `gh` credential helper.

This supersedes the laptop-identity clause of ADR-0004 ("Laptops use their own
1Password-backed identities") and the sentence in ADR-0006 that interactive use
reads real credentials from 1Password. The role model of ADR-0004 and the
profile model of ADR-0006 stand; the only change in the unattended path is
that the secret branch of `.zshenv` is selected by the presence of an identity
file instead of the `op` binary.

## Consequences

- The plaintext copies on disk (`~/.zshenv`, `~/.config/secrets/api-keys.yaml`)
  match the threat model the repository already accepted: `~/.zshenv` was
  plaintext before. FileVault and file modes protect them at rest.
- Git history keeps every ciphertext version. A revoked identity can still
  read the versions it was a recipient of, so a lost laptop also means
  rotating the values, not only revoking the recipient.
- Enrolling a machine needs an enrolled machine to re-encrypt. Bootstrap of a
  brand-new laptop is a two-sided step; the runbook in
  `docs/machine-secrets.md` carries it.
- The age identity is the one file per laptop that chezmoi cannot restore.
  Losing it is a reinstall from the enrollment point of view.
- The `1password-cli` formula stays installed: other tooling on these machines
  uses it. Nothing in this repository calls it.
