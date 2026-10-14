#!/usr/bin/env bash
# PreCompact handoff builder.
#
# On any compaction, fork the session before it is compacted and have a cheap
# model extract only what serves the goal. The result is stored for the
# SessionStart injector to place in the model's context once compaction
# finishes.
#
# `/compact <goal>` names the goal; a bare `/compact` leaves it to the fork,
# which resumes the whole session and can read the goal out of it. Nothing
# upstream of this hook has to know or store a goal in advance.
#
# Vendored from kylesnowschwartz/claude-handoff at 26f5b4c (MIT, Copyright (c)
# 2025 Kyle Snow Schwartz). Upstream has been inactive since 2026-01-05, so
# fixes will not arrive on their own; it is copied here rather than installed
# as a plugin because plugin files are overwritten on update and neither of
# the two defects below could be kept fixed (KD2).
#
# Two deliberate departures from upstream:
#   - The pending handoff lives under ~/.cache, keyed by session id, instead of
#     `.git/handoff-pending/`. `mkdir -p .git/handoff-pending` fails outright in
#     a linked worktree, where `.git` is a file, and there is no `.git` at all
#     in the non-repository directories this setup also works in. Keying by
#     session also stops two concurrent worktree sessions overwriting each
#     other (KTD5).
#   - Any handoff already stored for this session is deleted before extraction
#     starts. An interrupted compaction leaves a handoff behind, and without
#     this the injector would deliver it after the next compaction, describing
#     a session state the operator has already moved past (R16).
#
# Fails open: any missing dependency, unreadable input, or failed extraction
# exits 0 and lets compaction proceed unchanged.

set -uo pipefail

command -v jq > /dev/null 2>&1 || exit 0

# The library owns the state path, the key encoding, and the extraction bound.
# ${HOME:-} rather than $HOME: under `set -u` an unset HOME would abort the
# hook with a non-zero status, which is the opposite of failing open.
CONTEXT_USAGE_LIBRARY="${CONTEXT_USAGE_LIBRARY:-${HOME:-}/.local/lib/context-usage.sh}"
[ -r "$CONTEXT_USAGE_LIBRARY" ] || exit 0
# shellcheck source=home/dot_local/lib/context-usage.sh
. "$CONTEXT_USAGE_LIBRARY" || exit 0

HANDOFF_STORE="${HANDOFF_STORE_DIR:-${HOME:-}/.cache/claude-handoff}"

handoff_file() {
  printf '%s/%s.json' "$HANDOFF_STORE" "$(context_usage_encode_key "$1")"
}

input=$(cat) || exit 0

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
[ -n "$session_id" ] || exit 0

trigger=$(printf '%s' "$input" | jq -r '.trigger // "auto"' 2>/dev/null) || exit 0
instructions=$(printf '%s' "$input" | jq -r '.custom_instructions // ""' 2>/dev/null) || exit 0
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null) || exit 0

store="$(handoff_file "$session_id")" || exit 0

# `handoff:` was this hook's original trigger word, and typing it is now
# redundant. Strip it so a session that still opens with it does not hand the
# extractor the literal string `handoff:` as its goal.
goal="${instructions#handoff:}"
goal="${goal#"${goal%%[![:space:]]*}"}"
goal="${goal%"${goal##*[![:space:]]}"}"

# A bare `/compact` reaches here with nothing. The fork resumes the entire
# session, so it is better placed to name the goal than anything this hook
# could have stored in advance -- ask it for the goal instead of supplying one.
if [ -n "$goal" ]; then
  goal_block="$goal"
else
  goal_block="The operator did not state a goal. Read the session and name the goal yourself: the work that is underway and still unfinished at the point of compaction. Treat what you name as the goal for every step below, and open your handoff by stating it."
fi

transcript_facts() {
  local path="$1" records facts edited commits last_user sibling

  # Source-tree tests pass fixture paths relative to home/, while fixtures live
  # beside it in the checkout. Use that sibling only when the exact path is not
  # readable and the sibling exists.
  if [ ! -r "$path" ] && [[ "$path" == */home/tests/* ]]; then
    sibling="${path%/home/tests/*}/tests/${path#*/home/tests/}"
    [ -r "$sibling" ] && path="$sibling"
  fi
  if [ -z "$path" ] || [ ! -r "$path" ]; then
    printf '<transcript_facts>\nFiles edited: None\nCommits made: None\nLast user request: None\n</transcript_facts>'
    return 0
  fi

  # Slurp once so a malformed JSONL transcript takes the same empty-facts path
  # as an unreadable transcript instead of partially describing the session.
  records=$(jq -s -c '.' "$path" 2>/dev/null) || {
    printf '<transcript_facts>\nFiles edited: None\nCommits made: None\nLast user request: None\n</transcript_facts>'
    return 0
  }

  facts=$(printf '%s' "$records" | jq -c '
    def message_content:
      .message.content? // empty;
    def tool_uses:
      message_content
      | if type == "array" then .[] | select(.type == "tool_use") else empty end;
    def tool_results:
      message_content
      | if type == "array" then .[] | select(.type == "tool_result") else empty end;
    def text_content:
      message_content
      | if type == "string" then .
        elif type == "array" then
          [ .[] | select(.type == "text") | (.text // "") ] | join("")
        else ""
        end;
    def recent_unique:
      reduce .[] as $item
        ([]; if index($item) == null then . + [$item]
             else map(select(. != $item)) + [$item]
             end)
      | .[-20:];
    def is_harness($text):
      (.isMeta == true)
      or ((.origin.kind? // "") | IN("task-notification", "system", "hook"))
      or ($text | test("(?i)(^|\\n)(hook feedback:|system reminder:)|<system-reminder>|<task-notification>|<command-name>|<command-message>|<local-command-stdout>|\\[Request interrupted by user\\]"));

    . as $records
    | [ $records[]
      | select(.type == "user")
      | tool_results
      | select((.is_error // false) != true)
      | .tool_use_id? // empty
    ] as $successful_ids
    | [ $records[]
        | select(.type == "assistant")
        | tool_uses
        | select((.name // "") | IN("Edit", "Write", "NotebookEdit"))
        | select(.id as $id | ($successful_ids | index($id)) != null)
        | if .name == "NotebookEdit"
          then (.input.notebook_path // .input.file_path // empty)
          else (.input.file_path // empty)
          end
        | select(type == "string" and length > 0)
      ]
      | recent_unique as $edited
      | [ $records[]
          | select(.type == "assistant")
          | tool_uses
          | select(.name == "Bash")
          | select((.input.command // "") | test("(^|[[:space:];|&])git([[:space:]]+[^;&|]*)?[[:space:]]+commit([[:space:]]|$)"))
          | .id
        ] as $bash_commit_ids
        | [ $records[]
            | select(.type == "user")
            | . as $record
            | tool_results
            | select(.tool_use_id as $id | ($bash_commit_ids | index($id)) != null)
            | (.content? // (if ($record.toolUseResult? | type) == "object"
                             then ($record.toolUseResult.stdout? // "")
                             else ($record.toolUseResult? // "")
                             end))
          | if type == "string" then .
            elif type == "array" then [ .[] | .text? // "" ] | join("")
            else ""
            end
          | split("\n")[]
          | try capture("^\\[[^]]+ (?<hash>[0-9a-fA-F]+)\\] (?<subject>.+)$") catch empty
          | "\(.hash) \(.subject)"
        ]
        | recent_unique as $commits
        | [ $records[]
            | select(.type == "user")
            | . as $record
            | ($record | text_content) as $text
            | select(($text | length) > 0)
            | select(($record | is_harness($text)) | not)
            | select(($record.message.content? | type) != "array" or
                     ([.[]? | select(.type == "tool_result")] | length) == 0)
            | $text
          ]
        | {edited: $edited, commits: $commits, last_user: (last // null)}
  ' 2>/dev/null) || {
    printf '<transcript_facts>\nFiles edited: None\nCommits made: None\nLast user request: None\n</transcript_facts>'
    return 0
  }

  edited=$(printf '%s' "$facts" | jq -r '.edited[]?' 2>/dev/null) || edited=''
  commits=$(printf '%s' "$facts" | jq -r '.commits[]?' 2>/dev/null) || commits=''
  last_user=$(printf '%s' "$facts" | jq -r '.last_user // empty' 2>/dev/null) || last_user=''

  printf '<transcript_facts>\n'
  if [ -n "$edited" ]; then
    printf 'Files edited:\n'
    while IFS= read -r path; do
      [ -n "$path" ] && printf -- '- %s\n' "$path"
    done <<< "$edited"
  else
    printf 'Files edited: None\n'
  fi
  if [ -n "$commits" ]; then
    printf 'Commits made:\n'
    while IFS= read -r commit; do
      [ -n "$commit" ] && printf -- '- %s\n' "$commit"
    done <<< "$commits"
  else
    printf 'Commits made: None\n'
  fi
  if [ -n "$last_user" ]; then
    printf 'Last user request: %s\n' "$last_user"
  else
    printf 'Last user request: None\n'
  fi
  printf '</transcript_facts>'
}

facts_block=$(transcript_facts "$transcript_path") || exit 0

# Clear before extracting, never after. An extraction that fails from here on
# must leave no handoff at all rather than the previous compaction's.
rm -f "$store" 2> /dev/null || true

command -v claude > /dev/null 2>&1 || exit 0

# The transcript facts are extracted locally so paths and commit names come
# from the record rather than from the forked model's memory.
prompt="You are generating a goal-focused Handoff for the next session. Context compaction is imminent.

${facts_block}

<goal>
$goal_block
</goal>

Your task: Extract ONLY the context from this session that the next agent needs to execute the goal above. Be ruthlessly selective—irrelevant context is worse than missing context.

Before providing your handoff, analyze the conversation in <analysis> tags:

1. Restate the goal in your own words
2. Chronologically scan the session for information relevant to THIS GOAL:
   - Decisions, patterns, or constraints that affect the goal
   - Files modified or examined that relate to the goal
   - Errors encountered and how they were resolved
   - Current state of work that impacts the goal
3. Explicitly list what you are EXCLUDING and why
4. Verify: Does every item you're including directly serve the goal?

<analysis>
[Your systematic analysis here]
</analysis>

Then provide your handoff in this exact structure:

<handoff>
## Goal
[Restate the goal as a clear, actionable directive]

## Relevant Context
[3-7 bullet points of technical context that directly enables the goal]
[Each bullet must pass the test: \"The next agent cannot execute the goal without knowing this\"]

## Key Details
[Specific implementation details: file paths, function names, commands, error messages]
[Use exact names and paths—no paraphrasing]

## Warnings
[Blockers, gotchas, or critical constraints]
[Omit this section entirely if nothing applies]
</handoff>

Constraints:
- Maximum 400 words in the <handoff> section
- File paths only, not full code snippets (the agent can read files)
- Include verbatim quotes for anything where paraphrasing risks drift
- Copy file paths, commit hashes and subjects, and the last user request exactly from <transcript_facts>; do not paraphrase or infer replacements.
- If the goal is unclear or disconnected from session context, say so explicitly in your analysis and provide best-effort handoff

Do not:
- Include context \"just in case\" it might be useful
- Summarize the full session—that's not your job
- Invent next steps beyond what the goal specifies
- Include resolved issues unless they inform the goal"

# Write the model's output straight to a file. Capturing it in a shell
# variable corrupts backticks, command substitutions, globs, and null bytes.
extracted=$(mktemp "${TMPDIR:-/tmp}/handoff.XXXXXX" 2> /dev/null) || exit 0
trap 'rm -f "$extracted"' EXIT

status=0
claude --resume "$session_id" --fork-session \
  --model haiku --print "$prompt" > "$extracted" 2> /dev/null < /dev/null || status=$?

[ "$status" -eq 0 ] || exit 0
[ -s "$extracted" ] || exit 0

record=$(jq -n --rawfile content "$extracted" --arg goal "$goal" --arg trigger "$trigger" \
  '{handoff_content: $content, goal: $goal, trigger: $trigger, type: "compact"}' 2> /dev/null) || exit 0

context_usage_atomic_write "$store" "$record" 2> /dev/null || exit 0

exit 0
