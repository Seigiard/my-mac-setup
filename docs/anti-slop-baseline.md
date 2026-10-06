# Anti-slop baseline

Run `npm ci` and `npm run lint:anti-slop` with Node 24 or newer. `make lint` includes this check alongside the existing checks. A separate pull-request job runs the new check. The installation was checkout-only; the subsequent cleanup also changes managed hook and adapter source.

Owned hook modules, client adapters, tests, and Finicky settings stay in scope. Betterfox's vendored `browsers/firefox/user.js`, installed skill assets, dependency trees, and the lint plugin are excluded.

On the unchanged owned source at `39f0c2feaec49b134f2a4e4aead0b3df76b9374b`, Oxlint exits 1 with 607 anti-slop errors, including 512 `require-readable-spacing` findings. Other findings concern unknown inputs, runtime `typeof` checks, assertion safety comments, type widening, unsafe dictionary contracts, and conditional empty-object spreads. Representative locations include `home/dot_local/lib/agent-hooks/index.ts:38,72,99` and `home/private_dot_config/opencode/plugins/herdr-resource-context.ts:27,28`.

All 18 generic rules and native `oxc/no-accumulating-spread` remain enabled as errors. Owned manifests have no direct Effect dependency. No configured repository-wide TypeScript typecheck exists.

The authorized cleanup removes the 512 spacing findings and fixes the remaining 95 errors. Zod schemas decode tool events, marker files, and update-lock owners at their input boundaries. Named transport types replace unknown contracts. Encoders assign optional fields explicitly. Client adapters use their SDK contracts; the Intercom response wrapper uses direct method calls.

Zod is pinned to `4.3.6` in checkout tooling and in the two managed runtime packages. A chezmoi installer runs frozen npm installs after Node is available. Both CI test jobs install checkout dependencies. Both Docker test worktrees stage the manifests, lint configuration, and vendored plugin before installing checkout dependencies.

Local lint reports zero errors. The existing focused hook and adapter suites pass without changing their expected behavior. Deployment-sensitive changes require Ubuntu and macOS pull-request CI evidence on the published head; local lint alone is not that evidence. No findings are suppressed and every recorded anti-slop severity is preserved.
