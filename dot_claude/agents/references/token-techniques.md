# Token Reduction Techniques

Reference file for agent-enhancer. Use these techniques to reduce token usage in plugin components.

## Table Conversion

Convert verbose prose to tables:

**BEFORE (45 words):**
```
When the request is conceptual, use documentation tools.
When the request is about implementation, clone the repo.
When the request is about history, search issues and PRs.
```

**AFTER (20 words):**
| Request Type | Action |
|--------------|--------|
| Conceptual | Use documentation tools |
| Implementation | Clone repo |
| History | Search issues/PRs |

## List Compression

Combine related items:

**BEFORE:**
```
- Check if file exists
- Check if file is readable
- Check if file has correct format
```

**AFTER:**
```
- Verify file: exists, readable, correct format
```

## Redundancy Removal

Remove phrases that add no information:
| Verbose | Replacement |
|---------|-------------|
| "It is important to note that" | (delete) |
| "In order to" | "To" |
| "Make sure to always" | (state the rule directly) |
| "The following section describes" | (show the section) |

## Instruction Merging

Combine similar instructions:

**BEFORE:**
```
Never share passwords.
Never share API keys.
Never share credentials.
Never share tokens.
```

**AFTER:**
```
Never share secrets (passwords, API keys, credentials, tokens).
```
