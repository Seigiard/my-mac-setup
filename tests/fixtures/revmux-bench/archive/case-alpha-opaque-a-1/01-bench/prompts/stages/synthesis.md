You are merging a review panel's findings into one set. You are not reviewing code, you must not add a
finding of your own, and you must not judge whether a finding is true.

**Work from the findings text below and nothing else. Do not open files, do not run `git diff`, `rg`
or any other command, and do not go looking at the code.** Deciding whether two findings are the same
issue, which sources raised each, and which singletons are too weak to keep are all answerable from
what you have been given. A verifier runs after you with the code in front of it, and that is where
a finding is confirmed or rejected — duplicating it here spends a whole model run to reach a verdict
that is about to be reached properly, and an unverified opinion formed here contaminates the set the
verifier is handed.

Nothing you do writes anything. Do not modify, delete, move, stage or commit, and do not write a file
through a shell redirect.

## Sources that ran

6 sources ran, 6 reported.
- adversarial-claude (lenses: adversarial, adversarial-extended) reported 1 findings: adversarial-claude-1
- arch+quality-claude (lenses: architecture, architecture-extended, quality) reported 1 findings: arch+quality-claude-1
- docs+tests-claude (lenses: docs, tests, comments) reported 1 findings: docs+tests-claude-1
- docs+tests-codex (lenses: docs, tests, comments) reported no findings
- bugs+impl-codex (lenses: bugs, bugs-extended, impl) reported 1 findings: bugs+impl-codex-1
- lean-codex (lenses: simplify, efficiency, test-worth) reported no findings

Treat that list as fact. It is what actually ran, not what was requested — never infer the source
count from the findings themselves.

## Findings

[
  {
    "id": "adversarial-claude-1",
    "file": "console/contexts/account-data.ts",
    "line": 32,
    "end_line": 0,
    "severity": "minor",
    "confidence": 65,
    "title": "No retry on 401 removes the re-read that ran after AccountProvider cleared a stale Bearer token",
    "body": "Observed: the engine authenticates with only the Bearer token when one is present. In `engine/api/src/platform/auth/platform-auth.service.ts:1833-1843`, `resolveActorFromRequestToken` returns `authenticateFromToken(token)` and checks cookies only when there is no token. On a 401, `AccountProvider` (`console/contexts/account-context.tsx:51-58`) calls `unsetToken()` and `unsetImpersonationToken()`. Before this change, SWR's default retry ran `GET /account` again 5–15 s later. That request went out without the Bearer header, so a valid BetterAuth cookie returned 200 and the person was signed in again. `shouldRetryOnError: (error) =\u003e error.status !== 401` removes that re-read.\n\nWhat follows from this: an impersonation token lives 24 h in localStorage (`expiresIn = 86400`, platform-auth.service.ts:2898; set by `routes/Admin/PlatformUsers/Detail.tsx:165` and `JobsManagement.tsx:88`). Take an operator who still holds an expired one and opens a public `resolveAccount` page (`/offers/*/*`, `/start`, `/agreements/*`). They now stay signed out on that page until the next focus, reconnect or reload. `OfferSiteHeader` shows \"Log in\", and the StartPage views show the visitor state. Before, the person came back within seconds. Private routes are not affected: `RouteAuthBoundary` already redirected on the first 401, before any retry. The trigger needs an operator holding a stale impersonation token who opens a public offer or agreement link, so impact is limited to an internal user. Any focus or a click on \"Log in\" fixes it.",
    "fix": "Optional. Leave as is and accept recovery on focus. Or, in the 401 branch of the `AccountProvider` effect, call `mutate()` once when `unsetToken`/`unsetImpersonationToken` actually removed a token, so the cookie-only re-read still happens without a retry loop.",
    "sources": [
      "adversarial-claude"
    ],
    "lenses": [
      "adversarial"
    ],
    "verdict": ""
  },
  {
    "id": "arch+quality-claude-1",
    "file": "console/contexts/use-settled-account.ts",
    "line": 5,
    "end_line": 0,
    "severity": "minor",
    "confidence": 60,
    "title": "New hook's doc comment no longer says why the hook exists, or why it is a module of its own",
    "body": "The doc comment that StartPage dropped carried the reason the hook exists. A visitor's `/account` read fails. It runs again on retry and on a return to the tab, and SWR sets `isLoading` true each time because there is no data. Pages that draw a loading view on `loading` would then drop the sign-in form back to its first step. The new one-line comment (`Keeps account-dependent UI settled after its first account read completes.`) only says what the hook does, which the code already shows.\n\nTwo facts are now missing.\n- The caller contract: after the first read, `loading` stays false while a later read is in flight, so `loading: false` does not mean `user` is final.\n- Why the hook has its own module: many tests mock `contexts/use-account` with only `{ useAccount }`, which the goal states. A later engineer could fold it into `use-account.ts` and break those mocks without warning.\n\nThe repo's comment rule (CODING_STANDARDS.md §Comments: \"comments explain why code works the way it does now\"; the review profile: \"A comment explaining why the code is as it is now is wanted\") asks for exactly these constraints. This is a prose-only defect, so it rates minor.",
    "fix": "Restore the reason in the doc comment, stated in present tense. A visitor's account read repeats on retry and focus, `loading` would be true each time, and the hook reports `loading` only until the first read ends, so `user` can still change while `loading` is false. Add one line that says it is a module of its own because tests mock `contexts/use-account` with only `useAccount`.",
    "sources": [
      "arch+quality-claude"
    ],
    "lenses": [
      "quality",
      "architecture"
    ],
    "verdict": ""
  },
  {
    "id": "docs+tests-claude-1",
    "file": "console/contexts/use-settled-account.ts",
    "line": 5,
    "end_line": 0,
    "severity": "minor",
    "confidence": 60,
    "title": "useSettledAccount doc comment is vague, and wrong for a hook that starts settled",
    "body": "The new shared hook says only `/** Keeps account-dependent UI settled after its first account read completes. */`. Two problems.\n\n1. It does not state the contract that callers (`OfferSiteHeader`, `MembranePagesHeader`, `AgreementLinkPage` and three `StartPage` pages) rely on. Only `loading` is rewritten: it is true until the context first reports `loading: false`, then false for good. `user` and every other field pass through unchanged.\n\n2. It drops the reason the removed `StartPage` comment gave. A visitor's `/account` read fails and runs again on focus and reconnect, with SWR's `isLoading` true each time because `data` stays undefined. That would drop the sign-in form back to its first step and hide \"Log in\". A future editor who sees only \"keeps UI settled\" cannot tell why `useAccount` is not enough.\n\nThe \"after its first account read completes\" wording is also inaccurate in the case the goal asks about: `useState(!account.loading)` marks the hook settled at mount whenever the context is not loading. That includes a public page whose key is `null` (no `resolveAccount`, no sign-in hint), where no read ever ran. From that point the hook never reports `loading: true`, even if a read starts later.\n\nThe runtime behavior matches every caller today. The defect is in the prose only.",
    "fix": "Restore the substance of the removed StartPage comment on the hook, e.g. `/** The account, with \\`loading\\` true only until the context first reports it false — at mount, or when the first read ends — and false from then on. A visitor's read fails and runs again on focus and reconnect with \\`loading\\` true each time; pages that draw a loading view on it would hide \"Log in\" and drop a sign-in form back to its first step. */`",
    "sources": [
      "docs+tests-claude"
    ],
    "lenses": [
      "docs",
      "comments"
    ],
    "verdict": ""
  },
  {
    "id": "bugs+impl-codex-1",
    "file": "console/contexts/account-data.ts",
    "line": 32,
    "end_line": 0,
    "severity": "major",
    "confidence": 85,
    "title": "Отключение повторов ломает восстановление сессии после истечения impersonation token",
    "body": "Если открыть `/offers/.../start` с действующей cookie-сессией и просроченным `impersonationToken`, первый `/account` получает 401: сервер проверяет Bearer раньше cookie и не переходит к cookie после ошибки токена. `AccountProvider` удаляет просроченный токен, но не вызывает `mutate()`. До изменения повтор SWR перечитывал аккаунт уже через действующую cookie; новое условие отменяет это восстановление. Поэтому пользователь остаётся без `user` и получает форму входа вместо своего Start до следующей revalidation или перезагрузки. Это введённая изменением регрессия для действующей сессии.",
    "fix": "После удаления существовавшего Bearer-токена по 401 один раз перечитать аккаунт через cookie. Для посетителя без токена сохранить запрет автоматических повторов.",
    "sources": [
      "bugs+impl-codex"
    ],
    "lenses": [
      "bugs",
      "bugs-extended",
      "impl"
    ],
    "verdict": ""
  }
]

## What to produce

1. Split out what is not a defect in the change under review. A question the reviewer could not
   answer from the code goes to **open questions**; a defect in code the change did not touch goes to
   **pre-existing**. Move both out first: neither is deduped, boosted or dropped.

2. Deduplicate. Two findings are the same when they name the same file within two lines of each other
   and describe the same problem. Merge them into one, keeping the clearest title and body.

3. Confidence on a merged finding is `min(99, highest confidence + 10 * (distinct sources - 1))`.
   A source is a process. One process reporting the same problem under two of its lenses is still one
   source and earns no boost.

4. Severity is the highest severity any input claimed.

5. Drop a finding that has a single source, confidence below 80, and nothing corroborating it.
   Never drop a critical or a major this way — a single source is not evidence against a serious
   defect, and only one reviewer looking in the right place is the normal case for the worst bugs.
   Keep it and route it to the verifier, which is the authority on whether it is real.
   When the source list above shows the run was degraded, drop nothing: keep every would-be-drop and
   route it to the verifier instead. Corroboration is rarer with a source missing, so the drop rule
   starts eating findings the missing source would have confirmed, and the verifier is the authority
   anyway.

Every output finding carries the ids of the input findings it came from — one id when nothing was
merged. Attribution is derived from those ids, so an output with none is unusable.

As you work, narrate what you are doing. This is a running commentary read live by a human watching the run, and it is separate from your answer, which goes only in the structured output.

- Before each group of related tool calls, write one short line saying what you are about to check and why: "checking whether the stagger gate can still open on a fork".
- When something turns out to matter, say so in one line as you find it.
- Keep going for the whole review. Do not narrate the opening few steps and then fall silent for the rest of it — a reader who stops seeing lines cannot tell you apart from a hung process.
- One line at a time, under a dozen words, and never a summary of what you already said.
