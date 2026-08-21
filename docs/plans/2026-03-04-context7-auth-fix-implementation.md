---
status: superseded
superseded-by: commit c05718a — curl-based skills replaced by marketplace MCP plugins
---

# Context7 Skill Auth Fix — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add auth headers to Context7 SKILL.md so curl commands use the provisioned API key instead of hitting rate-limited free tier.

**Architecture:** Mirror the Jina Reader skill's auth pattern — `Authorization: Bearer $(printenv CONTEXT7_API_KEY)` in every curl command.

**Tech Stack:** Markdown (skill file), shell env vars

---

### Task 1: Update Context7 SKILL.md

**Files:**
- Modify: `home/private_dot_claude/skills/context7/SKILL.md`

**Step 1: Update frontmatter description**

Add `Requires CONTEXT7_API_KEY.` to the beginning of the `description` field in the YAML frontmatter:

```yaml
description: Retrieve up-to-date documentation for software libraries, frameworks, and components via the Context7 API. This skill should be used when looking up documentation for any programming library or framework, finding code examples for specific APIs or features, verifying correct usage of library functions, or obtaining current information about library APIs that may have changed since training.
```

→ becomes:

```yaml
description: Retrieve up-to-date documentation for software libraries, frameworks, and components via the Context7 API. Use when looking up documentation for any programming library or framework, finding code examples for specific APIs or features, verifying correct usage of library functions, or obtaining current information about library APIs that may have changed since training. Requires CONTEXT7_API_KEY.
```

**Step 2: Add auth requirement line after Overview heading**

After the overview paragraph (line 10), add:

```
Requires `CONTEXT7_API_KEY` environment variable. Auth: `Authorization: Bearer $(printenv CONTEXT7_API_KEY)`.
```

**Step 3: Add auth header to the 2 workflow curl commands**

Line 19 — search endpoint:
```bash
curl -s "https://context7.com/api/v2/libs/search?libraryName=LIBRARY_NAME&query=TOPIC" \
  -H "Authorization: Bearer $(printenv CONTEXT7_API_KEY)" | jq '.results[0]'
```

Line 39 — context endpoint:
```bash
curl -s "https://context7.com/api/v2/context?libraryId=LIBRARY_ID&query=TOPIC&type=txt" \
  -H "Authorization: Bearer $(printenv CONTEXT7_API_KEY)"
```

**Step 4: Add auth header to all 5 example curl commands**

React example — search (line 54):
```bash
curl -s "https://context7.com/api/v2/libs/search?libraryName=react&query=hooks" \
  -H "Authorization: Bearer $(printenv CONTEXT7_API_KEY)" | jq '.results[0].id'
```

React example — context (line 58):
```bash
curl -s "https://context7.com/api/v2/context?libraryId=/websites/react_dev_reference&query=useState&type=txt" \
  -H "Authorization: Bearer $(printenv CONTEXT7_API_KEY)"
```

Next.js example — search (line 64):
```bash
curl -s "https://context7.com/api/v2/libs/search?libraryName=nextjs&query=routing" \
  -H "Authorization: Bearer $(printenv CONTEXT7_API_KEY)" | jq '.results[0].id'
```

Next.js example — context (line 68):
```bash
curl -s "https://context7.com/api/v2/context?libraryId=/vercel/next.js&query=app+router&type=txt" \
  -H "Authorization: Bearer $(printenv CONTEXT7_API_KEY)"
```

FastAPI example — search (line 75):
```bash
curl -s "https://context7.com/api/v2/libs/search?libraryName=fastapi&query=dependencies" \
  -H "Authorization: Bearer $(printenv CONTEXT7_API_KEY)" | jq '.results[0].id'
```

FastAPI example — context (line 78):
```bash
curl -s "https://context7.com/api/v2/context?libraryId=/fastapi/fastapi&query=dependency+injection&type=txt" \
  -H "Authorization: Bearer $(printenv CONTEXT7_API_KEY)"
```

**Step 5: Remove the "no API key" tip**

Delete line 88:
```
- No API key is required for basic usage (rate-limited)
```

**Step 6: Verify the result**

Run: `grep -c 'Authorization: Bearer' home/private_dot_claude/skills/context7/SKILL.md`
Expected: `7` (2 workflow + 5 examples... wait, actually 2 workflow + 6 examples = 8 curl commands but the React example block has 2 commands in one block, Next.js has 2, FastAPI has 2 = 6 example commands + 2 workflow = 8 total)

Let me recount:
- Workflow: 2 curl commands (search + context)
- React: 2 curl commands (search + context)
- Next.js: 2 curl commands (search + context)
- FastAPI: 2 curl commands (search + context)
Total: 8 curl commands

Run: `grep -c 'Authorization: Bearer' home/private_dot_claude/skills/context7/SKILL.md`
Expected: `8`

Run: `grep 'No API key' home/private_dot_claude/skills/context7/SKILL.md`
Expected: no output

**Step 7: Commit**

```bash
git add home/private_dot_claude/skills/context7/SKILL.md
git commit -m "Add auth headers to Context7 skill curl commands"
```
