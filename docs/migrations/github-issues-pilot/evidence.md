# GitHub Issues migration pilot evidence

Issue: [#206](https://github.com/Seigiard/my-mac-setup/issues/206)

Scratch repository: `Seigiard/my-mac-setup-issue-migration-pilot-20260913`

Source commit: `5dc97b51af5dbbe1d4c6939927dcba1e0e975283`

Manifest SHA-256: `59327ddadeacb80fdd9e0be457cf842ec0bec9874da176b035b18b2f647f87a1`

## Oracle

The consumer is the temporary importer. A failure is an issue whose state read
back from the real GitHub API differs from the reviewed manifest, or a rerun
that mutates or duplicates a target. GitHub is independent of the importer and
is queried separately by `scripts/verify_github_issue_migration.py`; no fake API
or permanent tracker wrapper participates in the verdict.

## Representative set

The reviewed manifest contains nine records from the 59-record local corpus and
one synthetic in-progress record. It covers all source values currently present
for status, type, category, and priority, along with assignment-based
in-progress state, both terminal state reasons, parent plans, active-to-active
and active-to-terminal links, Unicode, code fences, the 8,506-byte largest
source body, the five-tag source maximum, and the two-label planned maximum.

The manifest was generated twice from the bound Git commit and compared with
`cmp`; both files were byte-identical.

## Pilot run

1. GitHub created the scratch repository at `2026-09-13T18:35:42Z` as private.
2. `verify ... empty` read back `private=true`, `has_issues=true`, and
   `issue_count=0`; `initial-state.json` retains that response.
3. `dry-run` emitted 68 conditional read, mutation, and read-back requests plus
   every target transformation to
   `dry-run.json`. It performs no GitHub call. A second `verify ... empty`
   returned `issue_count=0` after the dry-run.
4. `apply --interrupt-after-create 3` returned the intentional interruption
   status 75 after GitHub created and read back issue `#3`, but before its
   identity was written locally. The state file contained two mappings while a
   fresh GitHub query returned three issues with three distinct markers.
5. The resumed apply recovered issue `#3` from its marker, created only the
   seven remaining issues, closed two with their planned state reasons, and
   repaired three bodies containing six link occurrences:

   ```json
   {"bodies_repaired":3,"issues_closed":2,"issues_created":7,"issues_recovered":1,"labels_created":0,"mutations":12,"result":"complete"}
   ```

6. A completed rerun made no mutations:

   ```json
   {"bodies_repaired":0,"issues_closed":0,"issues_created":0,"issues_recovered":0,"labels_created":0,"mutations":0,"result":"noop"}
   ```

7. The independent verifier read all target pages and label definitions from
   GitHub. `target-export.json` retains exact titles, normalized bodies, visible
   provenance, hidden markers, labels, assignees, state reasons, and repaired
   links. Its final summary was:

   ```json
   {"duplicate_issue_count":0,"duplicate_marker_count":0,"issue_count":10,"repaired_link_count":6,"unmarked_issue_count":0,"verified":true}
   ```

8. Issue `#1` was deliberately renamed with a `[drift probe]` suffix. The next
   apply failed during preflight and did not restore the title. The exact error
   is retained in `drift-refusal.txt`, and `drift-readback.json` proves the edit
   remained on GitHub. After a manual scratch-only restoration, apply again
   returned `result=noop`, and the verifier reproduced the final passing export.

`run-log.txt` transcribes the exact terminal output and statuses for the
interrupted, resumed, no-op, drift, and final verification commands.

After deletion, the final verifier replayed the retained real-API export and
matched all 10 manifest entries and six repaired link occurrences. A copy with
one body corrupted was rejected; `replay-summary.json` and
`replay-rejection.txt` retain both verdicts and their command statuses.

## Retained artifacts

| Artifact | SHA-256 |
|---|---|
| `initial-state.json` | `ad94992f7319253c6e1e7d25569fcecf5f017b825b37502c978d22043bac01c1` |
| `manifest.json` | `59327ddadeacb80fdd9e0be457cf842ec0bec9874da176b035b18b2f647f87a1` |
| `dry-run.json` | `6b7df3ef66209326ebdd636ffc385d68b57b0745df3081424ab104d9b288fcaa` |
| `import-state.json` | `d36aea6bc72dd323923a2669dc6fb3791a36a68b60b01f69b6fd208e63290e1c` |
| `target-export.json` | `b771a6acff9c4065348e3355e721461b31ed506614d092d1725b982c96870511` |
| `run-log.txt` | `76fc3670c9cf32f0e8a336d6a0a00e052685bfac5a9b719a5ae9ea2d2585a1b7` |
| `drift-refusal.txt` | `d4db9072e3d7286c944375ce00b6c56dcab2fb6eda7f7dbad1e1a102cf0c0ebb` |
| `drift-readback.json` | `26bc141f2a04e09bee9b6a1c7ceb2834b721db27e42fbab98d6cb4f2c56e1ba3` |
| `replay-summary.json` | `da0a5abb9977595a1be65801033056b2a0167ae47f014ddf71a3b333c83c1ffa` |
| `replay-rejection.txt` | `f1e5bab2636a3a580cf8eabb9b17bcfbe83d43cf62346a5b78787785c7df2f75` |
| `deletion-readback.txt` | `d2c8985c89b29a842ac4946d13bdbc297709f44f20bb968faf9682664b211db6` |

The live-pilot artifacts through `target-export.json` and the drift evidence
were written before scratch deletion. `deletion-readback.txt` retains the
subsequent `HTTP 404` confirmation; replay artifacts were produced afterward
from the retained real-API export. The importer and verifier remain temporary
migration tools for the production slices and are scheduled for removal by
issue #210.
