# Example Transformations

Reference file for agent-enhancer. Examples of before/after improvements.

## Bloated Description

**BEFORE (verbose, no examples):**
```yaml
description: This agent should be used whenever you need help with code review tasks. It can review pull requests, analyze code quality, find bugs, suggest improvements, and help with best practices. Use it for any code review needs.
```

**AFTER (concise with examples):**
```yaml
description: |
  Use this agent when reviewing code for quality, bugs, or best practices.

  <example>
  Context: User opened a PR and wants feedback.
  user: "Review my changes in PR #42"
  assistant: "I'll analyze your PR for quality and potential issues."
  <commentary>
  Direct code review request triggers this agent.
  </commentary>
  </example>
```

## Verbose System Prompt

**BEFORE:**
```markdown
## Introduction
This agent is designed to help users with their code review needs.
It has been created to provide comprehensive analysis of code quality.

## What This Agent Does

This agent will review code and provide feedback. It looks at various
aspects of code quality including readability, maintainability, and
potential bugs. The agent uses best practices to evaluate code.
```

**AFTER:**
```markdown
You are a code review specialist. Analyze code for:
- Bugs and logic errors
- Readability issues
- Performance concerns
- Security vulnerabilities

## Process
1. Read the code completely
2. Identify issues by category
3. Suggest specific fixes with examples
```
