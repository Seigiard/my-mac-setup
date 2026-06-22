---
name: react-doctor
description: Run after making React changes to catch issues early. Use when reviewing code, finishing a feature, or fixing bugs in a React project.
---

# React Doctor

Scans your React codebase for security, performance, correctness, and architecture issues. Outputs a 0-100 score with actionable diagnostics.

## Usage

```bash
npx -y react-doctor@latest . --verbose --scope files --no-telemetry -y
```

Always use `--scope files` to scan only changed files, never the entire project. Add `--no-telemetry` to skip telemetry and `-y` to skip interactive prompts.

## Workflow

Run after making React changes to catch issues early. Fix errors first, then re-run to verify the score improved.
