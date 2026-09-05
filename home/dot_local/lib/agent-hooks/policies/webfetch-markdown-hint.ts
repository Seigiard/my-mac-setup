// Reminder for a direct web fetch.
//
// The tool table names /markdown-new as the primary path for a URL, but past
// sessions show the direct fetch at 51 calls against 3 for the skill. This
// policy never blocks: the direct fetch is sometimes the only path that works.
// It injects one line of context so the choice is deliberate — which is why its
// only outcome is `context`, and why the registry derives it applicable solely
// where that outcome exists.

import type { Decision, NormalizedEvent, Policy } from "../types.ts";
import { ALLOW, context } from "../types.ts";

const NAME = "webfetch-markdown-hint";

const PREFERRED_HOST = "markdown.new";

const HINT =
  "Reminder: /markdown-new returns cleaner markdown for this URL, needs no API key, and handles JS-heavy pages that WebFetch renders as an empty shell. Keep WebFetch only if the skill already failed on this page or the content is plain HTML.";

function evaluate(event: NormalizedEvent): Decision {
  const url = event.url;
  if (url === "" || url.includes(PREFERRED_HOST)) return ALLOW;
  return context(HINT);
}

export const webfetchMarkdownHint: Policy = {
  name: NAME,
  tools: ["web-fetch"],
  outcomes: ["context"],
  evaluate,
};
