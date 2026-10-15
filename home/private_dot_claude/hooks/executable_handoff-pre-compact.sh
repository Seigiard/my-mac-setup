#!/usr/bin/env bash
# PreCompact handoff builder.
#
# On any compaction, fork the session before it is compacted and have a
# low-effort model extract only what serves the goal. The result is stored for the
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
# Four deliberate departures from upstream:
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
#   - The extraction prompt includes a locally derived `<transcript_facts>`
#     block so paths, commits, and the last operator request come from the
#     transcript rather than the forked model's memory.
#   - A bare `/compact` gets a filled `<goal>` block that asks the fork to name
#     the unfinished work, instead of leaving the goal empty.
#
# Fails open: any missing dependency, unreadable input, or failed extraction
# exits 0 and lets compaction proceed unchanged. Once a session id is known,
# delivery failures are saved for the SessionStart hook to show the operator.

set -uo pipefail

# The extraction fork is itself a Claude Code session with this hook installed.
# If it compacts, this hook would fork it again, and each fork would fork the
# next until the outer timeout killed the chain. One observed run left 49 forks.
[ -z "${HANDOFF_FORK:-}" ] || exit 0

command -v jq > /dev/null 2>&1 || exit 0

# The library owns the state path and key encoding. ${HOME:-} rather than $HOME
# avoids turning an unset HOME into a hook failure under `set -u`.
CONTEXT_USAGE_LIBRARY="${CONTEXT_USAGE_LIBRARY:-${HOME:-}/.local/lib/context-usage.sh}"
[ -r "$CONTEXT_USAGE_LIBRARY" ] || exit 0
# shellcheck source=home/dot_local/lib/context-usage.sh
. "$CONTEXT_USAGE_LIBRARY" || exit 0

HANDOFF_STORE="${HANDOFF_STORE_DIR:-${HOME:-}/.cache/claude-handoff}"
HANDOFF_LOG_FILE="${HANDOFF_LOG_FILE:-$HANDOFF_STORE/handoff.log}"

handoff_file() {
  printf '%s/%s.json' "$HANDOFF_STORE" "$(context_usage_encode_key "$1")"
}

# Extraction time and transcript size show where the timeout boundary lies.
# Either is null when the run ended before it was known.
log_outcome() {
  local outcome="$1" record directory elapsed=""
  [ -z "${started:-}" ] || elapsed=$((SECONDS - started))
  record=$(jq -nc --arg session_id "$session_id" --arg trigger "$trigger" --arg goal "$goal" --arg outcome "$outcome" \
    --arg elapsed "$elapsed" --arg transcript_bytes "${transcript_bytes:-}" \
    '{session_id: $session_id, trigger: $trigger, goal: $goal, outcome: $outcome,
      elapsed_seconds: ($elapsed | if . == "" then null else tonumber end),
      transcript_bytes: ($transcript_bytes | if . == "" then null else tonumber end)}' 2> /dev/null) || return 0
  directory="${HANDOFF_LOG_FILE%/*}"
  [ "$directory" != "$HANDOFF_LOG_FILE" ] || directory="."
  [ -d "$directory" ] || mkdir -p "$directory" 2> /dev/null || return 0
  printf '%s\n' "$record" >> "$HANDOFF_LOG_FILE" 2> /dev/null || true
}

store_failure() {
  local reason="$1" record
  record=$(jq -nc --arg reason "$reason" '{failure_reason: $reason, type: "compact_failure"}' 2> /dev/null) || {
    log_outcome write
    return 1
  }
  if context_usage_atomic_write "$store" "$record" 2> /dev/null; then
    log_outcome "$reason"
    return 0
  fi
  log_outcome write
  return 1
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
  local path="$1" records facts

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
    def bounded_text:
      if length > 4000 then .[0:4000] + " [truncated]" else . end;
    def is_human_slash_command($text):
      (.origin.kind? == "human")
      and ($text | test("<command-name>/[^<]+</command-name>"));
    def slash_command($text):
      ($text | capture("<command-name>(?<name>/[^<]+)</command-name>(?:\\n<command-args>(?<args>[\\s\\S]*?)</command-args>)?"))
      | .name + (if (.args // "") == "" then "" else " " + .args end);
    def unwrap_pasted_content:
      if test("^[[:space:]]*<pasted_content id=\"[^\"]*\">\\n") then
        sub("^[[:space:]]*<pasted_content id=\"[^\"]*\">\\n"; "")
        | sub("\\n</pasted_content id=\"[^\"]*\">[[:space:]]*$"; "")
      else .
      end;
    def is_non_parent_protocol_marker($text):
      ($text | unwrap_pasted_content) as $marker_text
      | ($marker_text | test("^\\[[a-z]+(-[a-z]+)+ v[0-9]+([ \\n\\]])")) as $is_marker
      | ($marker_text | test("^\\[parent-(prompt|reply) v[0-9]+([ \\n\\]])")) as $is_parent
      | ($is_marker and ($is_parent | not));
    def recent_unique:
      reduce .[] as $item
        ([]; if index($item) == null then . + [$item]
             else map(select(. != $item)) + [$item]
             end)
      | .[-20:];
    def is_harness($text):
      (.isMeta == true)
      or (.isCompactSummary == true)
      or ((.origin.kind? // "human") != "human")
      or is_non_parent_protocol_marker($text)
      or ($text | test("^/compact(?:[[:space:]]|$)"))
      or (is_human_slash_command($text)
          and (($text | capture("<command-name>(?<name>/[^<]+)</command-name>") | .name) == "/compact"))
      or ((.origin.kind? != "human")
          and ($text | test("(?i)(^|\\n)(hook feedback:|system reminder:)|<system-reminder>|<task-notification>|<local-command-(stdout|stderr)>|<(local|bash)-(stdout|stderr)>|<bash-input>|^\\[Request interrupted by user( for tool use)?\\]|<command-name>|<command-message>")));

    def queued_as_user:
      if .type == "attachment"
         and (.attachment.type? == "queued_command")
         and (.attachment.commandMode? == "prompt")
         and ((.attachment.prompt? | type) | IN("string", "array"))
      then {type: "user", message: {role: "user", content: .attachment.prompt}, origin: .attachment.origin?, isMeta: .attachment.isMeta?}
      else .
      end;

    map(queued_as_user) as $records
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
            | select(((message_content | type) != "array") or
                     ((message_content | any(.[]?; .type == "tool_result")) | not))
            | if ($record | is_human_slash_command($text)) then
                slash_command($text)
              else $text
              end
            | bounded_text
          ]
        | {edited: $edited, commits: $commits, last_user: (last // null)}
  ' 2>/dev/null) || {
    printf '<transcript_facts>\nFiles edited: None\nCommits made: None\nLast user request: None\n</transcript_facts>'
    return 0
  }

  printf '%s' "$facts" | jq -r '
    def json_literal: tojson | gsub("<"; "\\u003c");
    "<transcript_facts>",
    (if (.edited | length) > 0 then
       "Files edited:", (.edited[] | "- " + json_literal)
     else "Files edited: None"
     end),
    (if (.commits | length) > 0 then
       "Commits made:", (.commits[] | "- " + json_literal)
     else "Commits made: None"
     end),
    (if .last_user == null then "Last user request: None"
     else "Last user request: " + (.last_user | json_literal)
     end),
    "</transcript_facts>"
  ' 2>/dev/null || {
    printf '<transcript_facts>\nFiles edited: None\nCommits made: None\nLast user request: None\n</transcript_facts>'
  }
}

facts_block=$(transcript_facts "$transcript_path") || exit 0

transcript_bytes=""
if [ -n "$transcript_path" ] && [ -r "$transcript_path" ]; then
  transcript_bytes=$(wc -c < "$transcript_path" 2> /dev/null | tr -d '[:space:]') || transcript_bytes=""
  case "$transcript_bytes" in *[!0-9]*) transcript_bytes="" ;; esac
fi

# Clear before extracting, never after. An extraction that fails from here on
# must leave no handoff at all rather than the previous compaction's.
rm -f "$store" 2> /dev/null || true

command -v claude > /dev/null 2>&1 || {
  store_failure dependency
  exit 0
}

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
[Bullet points of technical context that directly enables the goal]
[Each bullet must pass the test: \"The next agent cannot execute the goal without knowing this\"]
[When an item is inferred rather than observed, write it as: <claim>, verify with: <exact command>]

## Last request
[Quote the operator's last real message verbatim from the facts block above as a Markdown blockquote, with every line prefixed by \`> \`]
Status: [Use exactly one of: Answered, Partially answered, Not answered]
[When the request is not fully answered, name what to check first]

## Key Details
[Specific implementation details: file paths, function names, commands, error messages]
[When an item is inferred rather than observed, write it as: <claim>, verify with: <exact command>]
[Use exact names and paths—no paraphrasing]

## Warnings
[Blockers, gotchas, or critical constraints]
[Omit this section entirely if nothing applies]
</handoff>

Constraints:
- Maximum 400 words in the <handoff> section
- The verbatim quote in ## Last request does not count toward the 400-word cap
- File paths only, not full code snippets (the agent can read files)
- Include verbatim quotes for anything where paraphrasing risks drift
- Copy file paths, commit hashes and subjects, and the last user request exactly from <transcript_facts>; do not paraphrase or infer replacements.
- Fact values are JSON string literals; the character < is written as \\u003c. Decode each literal and copy its text exactly into the handoff without changing or paraphrasing it.
- If the goal is unclear or disconnected from session context, say so explicitly in your analysis and provide best-effort handoff

Do not:
- Include context \"just in case\" it might be useful
- Summarize the full session—that's not your job
- Invent next steps beyond what the goal specifies
- Include resolved issues unless they inform the goal"

# Write the model's output straight to a file. Capturing it in a shell
# variable corrupts backticks, command substitutions, globs, and null bytes.
extracted=$(mktemp "${TMPDIR:-/tmp}/handoff.XXXXXX" 2> /dev/null) || {
  store_failure write
  exit 0
}
trap 'rm -f "$extracted"' EXIT

# Claude Code terminates this hook at 240 seconds, the `timeout` registered in
# private_settings.json.tmpl. The 10-second margin leaves room for the SIGTERM
# grace period below. Polling avoids relying on a platform-specific timeout
# command while still recording an earlier timeout.
timeout_seconds="${HANDOFF_TIMEOUT_SECONDS:-230}"
case "$timeout_seconds" in
  '' | *[!0-9]*) timeout_seconds=230 ;;
esac
[ "$timeout_seconds" -le 230 ] || timeout_seconds=230

# The fork must hold the whole pre-compaction context. Haiku's 200k window could
# not hold a 341k-token session, so the fork compacted itself instead of
# answering. Sonnet has a 1M window.
HANDOFF_FORK=1 claude --resume "$session_id" --fork-session \
  --model sonnet --effort low --print "$prompt" > "$extracted" 2> /dev/null < /dev/null &
claude_pid=$!
started=$SECONDS
timed_out=0
while kill -0 "$claude_pid" 2> /dev/null; do
  if [ "$((SECONDS - started))" -ge "$timeout_seconds" ]; then
    timed_out=1
    kill "$claude_pid" 2> /dev/null || true
    break
  fi
  sleep 0.1
done

status=0
if [ "$timed_out" -eq 1 ]; then
  # SIGTERM is cooperative. Do not let a process that ignores it outlive the
  # hook's 240-second Claude Code limit.
  kill "$claude_pid" 2> /dev/null || true
  grace_started=$SECONDS
  while kill -0 "$claude_pid" 2> /dev/null; do
    if [ "$((SECONDS - grace_started))" -ge 5 ]; then
      kill -KILL "$claude_pid" 2> /dev/null || true
      break
    fi
    sleep 0.1
  done
  wait "$claude_pid" 2> /dev/null || true
  store_failure timeout
  exit 0
fi
wait "$claude_pid" || status=$?
[ "$status" -eq 0 ] || {
  store_failure fork
  exit 0
}
[ -s "$extracted" ] || {
  store_failure empty
  exit 0
}

record=$(jq -n --rawfile content "$extracted" --arg goal "$goal" --arg trigger "$trigger" \
  '{handoff_content: $content, goal: $goal, trigger: $trigger, type: "compact"}' 2> /dev/null) || {
  store_failure write
  exit 0
}

context_usage_atomic_write "$store" "$record" 2> /dev/null || {
  store_failure write
  exit 0
}
log_outcome stored

exit 0
