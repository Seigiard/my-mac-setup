---
allowed-tools: Bash(jq:*), Bash(test:*), Bash(claude plugin:*), Bash(echo:*), Bash(cat:*), Bash(ls:*)
description: Check and repair broken Claude Code plugins
---

<command>

<context>
- Plugin status from CLI: !`claude plugin list --json 2>/dev/null || echo '[]'`
</context>

<task>
You are a plugin health checker. Analyze plugin status and cache integrity.

<process>
1. Parse the JSON array from context. Each entry has: `id`, `version`, `scope`, `enabled`, `installPath`, optionally `projectPath`.

2. For each plugin, run TWO checks:
   a. **Enabled check**: is `"enabled": true`?
   b. **Cache check**: does `installPath` directory exist AND contain at least one subdirectory (commands/, skills/, agents/, hooks/, .claude-plugin/)?
      Run: `test -d "<installPath>" && ls "<installPath>/" | head -5`

3. Classify results:
   - **HEALTHY**: enabled=true AND cache has content
   - **DISABLED**: enabled=false (just report, don't fix — user may have disabled intentionally)
   - **BROKEN**: enabled=true BUT cache is empty/missing → needs reinstall
   - **GHOST**: enabled=false AND cache is empty/missing → stale entry, suggest removal

4. For each BROKEN plugin with user scope:
   - Run: `claude plugin uninstall -s user "<id>"`
   - Then: `claude plugin install -s user "<id>"`
   - Verify fix: re-run cache check
   - If install fails, report the error and continue to next plugin

5. For each BROKEN plugin with project/local scope:
   - Output a warning with the exact copy-paste command:
     `cd <projectPath> && claude plugin uninstall -s <scope> "<id>" && claude plugin install -s <scope> "<id>"`

6. Print a summary report:
```
Plugin Doctor Report
────────────────────
HEALTHY   <N> plugins OK
DISABLED  <N> plugins disabled (intentional)
FIXED     <N> plugins reinstalled
FAILED    <N> plugins failed to reinstall
WARNING   <N> plugins need manual fix (project/local scope):
  → <copy-paste command for each>
GHOST     <N> stale entries (disabled + no cache):
  → claude plugin uninstall -s <scope> "<id>"
```

Omit sections with 0 count (except HEALTHY).
</process>

<rules>
- Do NOT modify installed_plugins.json directly — use `claude plugin` CLI only
- Process ALL plugins, do not stop on first error
- Run uninstall before install to clear stale state
- Use the `id` field as-is for plugin commands (format: name@marketplace)
- DISABLED plugins are NOT broken — do not attempt to fix them
</rules>

</task>

</command>
