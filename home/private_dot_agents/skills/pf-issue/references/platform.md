# platform repo cache

What the repo does not confess in one lookup. Verify against `AGENTS.md` when something here fails.

## Contracts

Eight contracts, each a prose overview at `contracts/<name>.md` (the rules) plus built artifacts under `contracts/<name>/` (never hand-edited; rebuilt by `bun run contracts:build:<name>`). Read both halves; past audits that read only the JSON missed the governing sentence in the prose.

| Contract | Artifact | Fed by |
|---|---|---|
| security | `security/{glossary,behaviors,command-declarations,unscoped-baseline}.json` | `sdk/src/security/glossary.ts`; `describe('security:…')` / `it()` titles in tests |
| api | `api/{commands-manifest,rest-only-endpoints}.json` | `sdk/src/commands/*.ts` `defineCommand` fields (`requires`, `requiresAccess`, `requiresOperatorClaim`, `bypassFor`); `MovedRoute` declarations |
| ux | `ux/ux-manifest.json` | `@ux-route` e2e specs, stories |
| ai | `ai/agent-context-manifest.json` | preset and tool mounts |
| information-architecture | `information-architecture/entity-manifest.json` | test titles (every renamed `it()` moves it) |
| communications | `communications/notification-catalog.json` | `engine/api/src/platform/notifications/notification-catalog.ts`; `@notification` tests (backticks in titles break the lifter) |

Contract-grade declarations outside `contracts/`: `sdk/src/workspace-elements-catalog/index.ts` (`clientSurface`, `permissionParent`, `defaultGrant`), `PRODUCT.md`, `console/CLAUDE.md` doctrine, `docs/{operators,jobs,sharing-and-permissions,agent}.md`, `engine/api/src/workspace/resource-grants/creation-time-grants.md`.

Impact labels are decided by `scripts/contracts/impact.ts`, `scripts/contracts/ai/ai-contract.ts`, `scripts/contracts/communications/notification-catalog-diff.ts`; which label blocks merge and who may override lives in `contracts/override-policy.json` and `.github/workflows/pr.yml`. `Security: Breaking` needs a human-only override label. Read the classifier to the end before stating a label.

## Tracker

- Read: `linear issue view PRD-NNNN` (full output to a file). If `linear` is missing use `bunx @schpet/linear-cli …`; `npx` is banned in the repo.
- Siblings: `linear issue query --team PRD --search "<words>"`.
- Write: `linear issue comment add --body-file`, `linear issue update --state`, `linear issue create --team PRD --description-file … --assignee <display name> --no-interactive`, `linear issue relation add <A> blocked-by <B>`.

## Primary evidence

- Dev database rows: `docker exec … psql` against the dev stack.
- Live UX by role: dev stack in a herdr pane, `bun run dev:wait`, then "View as…" impersonation; a Vite dev-auto-login plugin rewrites `localStorage.jwt`, so the PAT does not switch seats by itself.
- A failing test file of unclear origin: run it against `origin/main` before blaming the change; `git log -- <file>` tells where it came from.
