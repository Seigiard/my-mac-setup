#!/usr/bin/env bash
# Claude Code PreToolUse entry point for the shared agent-hooks dispatch core.
#
# Deliberately not an `executable_`-prefixed bun script: settings invokes it as
# `bash '<path>'`, and a bun shebang under that prefix turns `make lint` red
# (SC1071). Both guards below are the fail-open invariant (R4) — bun is absent
# at apply time on the macOS CI job, and a core file that has not landed yet
# must let the tool call through. Neither guard prints: this hook runs on every
# matched tool call, so a degraded state that spoke would flood the transcript.

set -uo pipefail

command -v bun >/dev/null 2>&1 || exit 0

core="${HOME:-}/.local/lib/agent-hooks/claude.ts"
[ -f "$core" ] || exit 0

exec bun "$core"
