#!/usr/bin/env bash
# Read the partner's pane (or stdin) and extract its latest pair reply.
#
#   recv.sh --self-role a --partner-role b --sid S [--partner-pane P] [--lines N]
#
# Model B: the partner replies in its own pane; the initiator parses that reply here. We
# look for the LAST header addressed to us — `[pair <partner-role> -> <self-role> kind=K
# sid=S]` — tolerating the leading whitespace the TUI indents transcript lines with. On a
# match, the kind is printed on line 1 (the state-machine signal), then a blank line, then
# the body (best-effort, for the caller to read). Pure text in via stdin → unit-testable.
#
# Exit: 0 ok; 2 usage; 3 no reply addressed to us found; 4 a reply was found but its sid
# does not match (a protocol violation the caller must surface, not invent state around).
set -euo pipefail

SELF_ROLE="" ; PARTNER_ROLE="" ; SID="" ; PARTNER_PANE="" ; LINES=80
while [ $# -gt 0 ]; do
  case "$1" in
    --self-role)    SELF_ROLE="$2"    ; shift 2 ;;
    --partner-role) PARTNER_ROLE="$2" ; shift 2 ;;
    --sid)          SID="$2"          ; shift 2 ;;
    --partner-pane) PARTNER_PANE="$2" ; shift 2 ;;
    --lines)        LINES="$2"        ; shift 2 ;;
    *) echo "recv.sh: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$SELF_ROLE" ]    || { echo "recv.sh: --self-role required" >&2; exit 2; }
[ -n "$PARTNER_ROLE" ] || { echo "recv.sh: --partner-role required" >&2; exit 2; }
[ -n "$SID" ]          || { echo "recv.sh: --sid required" >&2; exit 2; }

if [ -n "$PARTNER_PANE" ]; then
  command -v herdr >/dev/null || { echo "recv.sh: herdr not on PATH" >&2; exit 1; }
  TEXT="$(herdr pane read "$PARTNER_PANE" --source recent-unwrapped --lines "$LINES")"
else
  TEXT="$(cat)"
fi

SELF_ROLE="$SELF_ROLE" PARTNER_ROLE="$PARTNER_ROLE" SID="$SID" \
  python3 - "$TEXT" <<'PY'
import os, re, sys

text = sys.argv[1]
self_role = re.escape(os.environ["SELF_ROLE"])
partner_role = re.escape(os.environ["PARTNER_ROLE"])
want_sid = os.environ["SID"]

# Tolerant of leading TUI decoration before the header — pi indents with spaces, Claude
# Code prefixes assistant lines with a "⏺ " bullet. `[^\w\[]*` swallows any run of
# non-word, non-'[' chars (glyphs, bullets, spaces) but stops at prose (a word char), so a
# header quoted mid-sentence ("... reply with [pair ...") is not mistaken for a real reply.
pat = re.compile(
    r'^[^\w\[]*\[pair\s+' + partner_role + r'\s*->\s*' + self_role +
    r'\s+kind=(\S+)\s+sid=(\S+?)\s*\]',
    re.M,
)
matches = list(pat.finditer(text))
if not matches:
    sys.exit(3)

m = matches[-1]
kind, sid = m.group(1), m.group(2)
if sid != want_sid:
    sys.stderr.write(f"recv.sh: sid mismatch (got {sid!r}, expected {want_sid!r})\n")
    sys.exit(4)

# Body: the lines after the header, up to the TUI input-box rule that follows the reply
# (a run of box-drawing dashes) — everything below that is pane chrome (rules, cwd, the
# cost/status line), not the partner's message. Best-effort; the kind above is exact.
out = []
for line in text[m.end():].splitlines():
    t = line.strip()
    if len(t) >= 10 and set(t) <= set("─-"):
        break
    out.append(line)
while out and not out[0].strip():
    out.pop(0)
while out and not out[-1].strip():
    out.pop()

print(kind)
print()
print("\n".join(line.strip() for line in out).strip())
PY
