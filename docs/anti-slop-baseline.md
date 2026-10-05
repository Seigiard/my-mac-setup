# Anti-slop baseline

This adds checkout-only npm tooling. It does not change managed home files or deployment. Run `npm ci` and `npm run lint:anti-slop` with Node 24 or newer. `make lint` includes this check alongside the existing checks. A separate pull-request job runs the new check.

Owned hook modules, client adapters, tests, and Finicky settings stay in scope. Betterfox's vendored `browsers/firefox/user.js`, installed skill assets, dependency trees, and the lint plugin are excluded.

On the unchanged owned source at `39f0c2feaec49b134f2a4e4aead0b3df76b9374b`, Oxlint exits 1 with 607 anti-slop errors, including 512 `require-readable-spacing` findings. Other findings concern unknown inputs, runtime `typeof` checks, assertion safety comments, type widening, unsafe dictionary contracts, and conditional empty-object spreads. Representative locations include `home/dot_local/lib/agent-hooks/index.ts:38,72,99` and `home/private_dot_config/opencode/plugins/herdr-resource-context.ts:27,28`.

All 18 generic rules and native `oxc/no-accumulating-spread` remain enabled as errors. Owned manifests have no direct Effect dependency. No configured repository-wide TypeScript typecheck exists.

This draft requires a separate spacing cleanup and contract review at parsing boundaries. No owned source is rewritten and no findings are suppressed. The new lint failure is not a passing baseline or evidence that the existing shell/deployment checks have passed.
