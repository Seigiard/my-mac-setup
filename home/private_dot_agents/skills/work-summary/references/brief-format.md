# Brief Format

A spoken brief: what the user tells a manager in a sync — what got done, what comes next, measured against the user's bets. The user reads it aloud or glances at it while talking, so it is prose in short paragraphs, Russian by default, three to four minutes spoken (about 400–550 words). Output is one `.md` file, written to the scratchpad unless the user names a place.

## The bets are the anchor

The bets live on the user's page in Notion, "People of Membrane": `https://app.notion.com/p/integration-app/Andrew-Borisenko-3bf825e266bd81569923fe396622c851`. Read it through the executor MCP (`notion_com…notion_fetch` with the page id; load `skills({ name: "execute" })` first if the workflow is unfamiliar). The page holds:

- **Mission** — one line. It frames the whole brief; it is not retold.
- **Active bets** — every `## Bet …` heading above `## Archive`. Each has Why, Limiting Factor, Success Conditions, Due, Evidence, and a Next steps checklist.
- **Archive** — closed bets as links. Skip it unless a bet closed inside the window.

The page wins over vector-prime here: `current_focus` describes the Slack update, the bets describe the user's commitments. The fetch's edit time is unreliable (it can report the fetch itself), so learn whether the bets changed inside the window from the conversation. When they did, that is news for the brief, told in one or two sentences: what changed, and why in plain words.

## Shape

Four sections, `##` headings, in this order:

1. **Ставки** — what moved on each active bet. Lead with the bet that moved most. Say what the work now gives a person, never which stage closed. A bet with no closed work in the window gets one sentence saying so.
2. **UI/UX** — what a user of the product now sees or can do that they could not before.
3. **Ошибки** — three to five user-visible bugs as "was → now", then the rest in one sentence: «Ещё было исправлено около N мелких ошибок и сделано несколько улучшений инфраструктуры». Count N from the issues left over after everything named elsewhere, and keep the «около».
4. **Что дальше** — one short paragraph per active bet: what it is in plain words, its due date, and the next unchecked step from its checklist.

Every done issue lands in exactly one place: a story in sections 1–3, or the leftover count. A Done issue whose description carries a "Done when" counts as finished as specified. When the outcome is in doubt, read the linked PR's title and the last comment; an issue whose description, PR and comments still disagree about how the work ended is left out of the text and named to the user outside the file.

## Stories, not tickets

Clusters of related issues are where the brief earns its time. Find them by shared words in titles and descriptions — "access", "links", one surface, one customer — and read the **problem** section of each issue in the cluster before writing. Then tell the cluster as one story:

- **The problem a person felt**, with the concrete case from the descriptions: a customer screen, a number from production, a real symptom. "A 200-row table sent 200 requests" lands; "batched access reads" does not.
- **Why it happened**, in one sentence, when the cause is what makes the fix make sense.
- **What is true now.**
- **Bugs found on the way**, named as symptoms.

Pick the two or three biggest clusters for full stories; smaller ones get one sentence each. When the text runs over the word target, cut the one-sentence items before a story loses its concrete case.

## Zero context, spoken

The listener has not seen the bets page, the tickets, or the code. The test for every sentence: would a colleague from another team understand it on first hearing?

- Name a bet by what it does — «агенты, которые смотрят записи сессий» — never by its number, its stage, or the page's own vocabulary ("side bet", "stop rule", "stage 2", "limiting factor").
- Tell outcomes. When the user's own tooling (an agent pipeline, a script) got a batch of internal fixes, the brief carries one sentence on what the tooling now does reliably; the fixes themselves — modes, memory limits, retries, data checks — go to the leftover count.
- Code stays out: no identifiers, paths, URL schemes, or ticket IDs. Say what the thing lets a person do.
- Product surface names stay as the user sees them on screen (Explore, Inbox, Work).
- Write real Russian words where one exists: рабочее пространство, доступ, перенаправление. Latin script only for what is literally on screen or a product name.

## Outside the file

After writing, tell the user in the conversation: the path, the source (N issues closed in the window, the bets page and its edit time), which issues were left out and why, and every number that is an estimate. Then let the user cut — the brief gets edited aloud, and every removal stands.

## Example (8 Oct 2026, excerpt)

> ## Ставки
>
> Главное за неделю: агенты теперь сами смотрят записи сессий наших пользователей в PostHog. Они находят места, где человек застрял или что-то сломалось, и заводят по ним задачи. Раньше я делал это руками на своей машине. Теперь это работает внутри Membrane, на нашем же продукте, и каждая находка приходит с ссылкой на нужную секунду записи.
>
> ## UI/UX
>
> Большая работа была про ссылки на данные. Пример — экран обзора каталога у Visibly. На нём есть карточки «SKU в продаже» и «скрыто из-за ошибки». По клику на карточку хочется сразу увидеть эти строки в таблице. Раньше это было невозможно: ссылка вела только на таблицу целиком. Теперь ссылка несёт фильтр, сортировку и поиск.
>
> Консоль раньше умела узнавать права пользователя только на один ресурс за запрос. Поэтому таблица на 200 строк отправляла 200 запросов, и в production за две недели набралось больше сотни отказов «слишком много запросов». Теперь права на много ресурсов приходят одним запросом на страницу.
>
> ## Что дальше
>
> Агенты, которые смотрят записи сессий, до 15 октября: проверку находок забирает Membranch, и человек видит только подтверждённые проблемы. 15 октября по цифрам решаю, оставить их, сузить или остановить.
