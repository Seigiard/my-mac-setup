# Machine secrets

How API keys and SSH keys reach a machine without a password manager in the
loop. The decision and its trade-offs are in
[ADR-0023](decisions/0023-deliver-machine-secrets-with-age-and-per-machine-identities.md);
the vocabulary (Machine identity, Enrollment, Revocation) is in
[`CONCEPTS.md`](../CONCEPTS.md).

## The model in one screen

```text
home/private_dot_config/secrets/encrypted_private_api-keys.yaml.age   (git: ciphertext)
        │  chezmoi apply, decrypted with ~/.config/chezmoi/key.txt
        ▼
~/.config/secrets/api-keys.yaml   (plaintext, mode 0600)
~/.zshenv                         (the same values, as `export` lines)
```

- **One secrets file.** `api-keys.yaml` is a flat YAML map, `NAME: "value"`,
  and the single source of truth for every API key the shell exports. It is
  encrypted for every enrolled laptop at once.
- **One identity per laptop.** `~/.config/chezmoi/key.txt` is an `age` key
  pair generated on that laptop. It never leaves the laptop and is never
  committed. Its public half is the `age_recipient` of the laptop's role in
  `home/.chezmoidata/machines.yaml`.
- **No identity, no secrets.** The server, CI, Docker, and a laptop before
  enrollment have no identity. There `.chezmoiignore` drops the decrypted
  target and `.zshenv` renders without the keys; apply still succeeds.
- **Identity present but unable to decrypt** (the file was encrypted before
  this laptop was enrolled): apply fails on `.zshenv`. That is deliberate. A
  shell silently missing its keys is harder to notice than a failed apply.
- **SSH keys are not secrets of the store.** Each laptop's private key sits at
  `~/.ssh/<role>` on that laptop only, with no passphrase. chezmoi manages the
  public keys and `authorized_keys`; the private key is placed by hand.

## Day to day

### Change or add a value

```sh
make edit-secrets        # decrypts into $EDITOR, re-encrypts on save
chezmoi apply            # re-renders ~/.zshenv and ~/.config/secrets/api-keys.yaml
git commit -am "Rotate <name>" && git push
```

On the other laptop: `chezmoi update`. Open a new shell to pick up the values.

`make edit-secrets` edits the file in this checkout (`--source=./home`), so the
commit lands here. It reads the identity and the recipients from the host
chezmoi config, which `chezmoi init` regenerates; see the enrollment note on
stale recipients below.

### Add a new exported variable

A new key needs more than a line in the secrets file, because the unattended
full-fixture profile renders `.zshenv` from canaries and keeps a count of them:

1. Add `NAME: "value"` through `make edit-secrets`.
2. Add `export NAME={{ $secrets.NAME | quote }}` to the age branch of
   `home/dot_zshenv.tmpl`, and the matching
   `export NAME={{ env "MMS_CHEZMOI_FIXTURE_NAME" | quote }}` to its
   full-fixture branch.
3. Register `MMS_CHEZMOI_FIXTURE_NAME` in
   `tests/helpers/chezmoi-unattended-targets.tsv`, raise the fixture count in
   `tests/helpers/chezmoi-unattended`, and set the canary in
   `tests/helpers/common.bash` and `.github/workflows/test-dotfiles.yml`.
4. Extend the canary assertion in `tests/bashunit/templates_test.sh`
   (tests 0091, 0093 and 0095 list every exported name).

## Enrollment: a new laptop, or a reinstalled one

On the **new laptop**, after its first `chezmoi apply` (the Brewfile installs
`age`; a first apply without an identity succeeds and simply brings no keys):

```sh
age-keygen -o ~/.config/chezmoi/key.txt
chmod 600 ~/.config/chezmoi/key.txt
age-keygen -y ~/.config/chezmoi/key.txt      # prints age1...
```

Put the printed public key into the laptop's role in
`home/.chezmoidata/machines.yaml` as `age_recipient`, commit, push.

On an **already enrolled laptop**:

```sh
git pull
chezmoi init                 # refreshes the recipient list in the host config
make reencrypt-secrets       # decrypts with this laptop's key, encrypts for all recipients
git commit -am "Enroll <role>" && git push
```

Back on the new laptop: `chezmoi init && chezmoi apply`. Until this step, the
new laptop has no API keys, and an apply there fails on `.zshenv` if a stale
secrets file is present with the identity already in place; pull first.

A reinstalled laptop is a new laptop: its old identity is gone with the disk.
Replace the role's `age_recipient` and re-encrypt the same way.

## Revocation: a lost or retired laptop

1. Remove `age_recipient` from the role in `machines.yaml`.
2. `chezmoi init && make reencrypt-secrets` on an enrolled laptop; commit, push.
3. Remove the role's public key from the other machines' `authorized_keys`
   lists in `machines.yaml` and from GitHub; apply on each machine.

Revocation stops the laptop from reading **future** versions. Every earlier
version in git history is still readable with its identity. For a lost or
compromised laptop, rotate the values themselves afterwards. For a laptop that
was retired in your hands, revocation alone is enough.

## SSH keys

| Role | Private key | Public key | Committed |
|---|---|---|---|
| `mbp2026` | `~/.ssh/mbp2026` | `~/.ssh/mbp2026.pub` | public key only |
| `mbp2021` | `~/.ssh/mbp2021` | `~/.ssh/mbp2021.pub` | public key only |
| `server` | none | none | nothing |

`~/.ssh/config` names the role's private key with `IdentitiesOnly yes` and no
agent, so every ssh and git-over-ssh call works in a remote session without a
prompt. The key has no passphrase: a passphrase in the macOS keychain is
unreachable from an SSH session with no GUI login, which is the situation this
model exists for. FileVault and file mode 0600 are the protection at rest; a
lost laptop is handled by revocation above.

To replace a laptop's key: `ssh-keygen -t ed25519 -f ~/.ssh/<role> -N ""`,
copy the new public key over `home/private_dot_ssh/<role>.pub`, replace the
matching entries in the other roles' `authorized_keys` lists in
`machines.yaml`, register it on GitHub, and apply on every machine. Keep one
session open to each machine until a fresh login succeeds.

The server keeps no outbound key (ADR-0004). Attended git access from the
server uses a dedicated forwarded session: `ssh -A server`.

GitHub HTTPS remotes use the `gh` token (`home/dot_gitconfig.tmpl`); that path
needs neither the SSH key nor an agent.

The 1Password app's SSH agent is not referenced anywhere any more. Keep it
turned off (**Settings → Developer → Use the SSH agent**) so nothing still
pointed at it brings its approval prompts back.
