# Repository issue guidance

`docs/issues/*.md` is the only authoritative issue corpus. Do not maintain a second
snapshot in this file.

List active issues in stable category, priority, and identifier order:

```sh
python3 scripts/issues list
```

Search titles, short descriptions, and bodies:

```sh
python3 scripts/issues search '<text>'
```

Use `--json` for machine-readable output. Both commands accept `--status`,
`--category`, `--priority`, `--type`, and `--tag` filters.
