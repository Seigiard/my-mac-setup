#!/usr/bin/env bash
# Read the partner's pane (or stdin) and extract its reply to the driver's latest message.
#
#   recv.sh --self-role a --partner-role b --sid S [--partner-pane P] [--lines N]
#
# Model B: the partner replies in its own pane; the initiator parses that reply here.
#
# Anti-stale/echo cursor: the driver's most recent OUTGOING header (self -> partner) is
# echoed into the partner pane and marks "after my last send". The current reply is the
# FIRST partner -> self header AFTER that cursor. This ignores stale prior replies and the
# echoed outgoing message itself (which IS the cursor) without needing a protocol nonce. If
# no outgoing header is in the window (e.g. stdin fixtures), it scans the whole text.
#
# Note: the `sid` only dedups stale traffic — it authenticates nothing. A partner can print
# any header it likes, so a parsed `accepted` is never sufficient on its own; the driver
# must independently verify the work, and the watching human is the final authority.
#
# On a match: kind on line 1 (the state-machine signal), a blank line, then the body
# (best-effort, for the caller to read). Pure text in via stdin → unit-testable.
#
# Exit: 0 ok; 2 usage; 3 no reply to the current turn found; 4 a reply was found but its sid
# does not match (a protocol violation the caller must surface, not invent state around).
set -euo pipefail

SELF_ROLE="" ; PARTNER_ROLE="" ; SID="" ; PARTNER_PANE="" ; LINES=200
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
# Code prefixes assistant lines with a "⏺ " bullet. `[^\w\[]*` swallows a run of non-word,
# non-'[' chars (glyphs, bullets, spaces) but stops at prose (a word char), so a header
# quoted mid-sentence ("... reply with [pair ...") is not mistaken for a header line.
deco = r'^[^\w\[]*\['

# Cursor: the driver's most recent outgoing header (self -> partner).
out_pat = re.compile(deco + r'pair\s+' + self_role + r'\s*->\s*' + partner_role + r'\b', re.M)
outs = list(out_pat.finditer(text))
region_start = outs[-1].end() if outs else 0

# The reply is the first partner -> self header at or after the cursor.
reply_pat = re.compile(
    deco + r'pair\s+' + partner_role + r'\s*->\s*' + self_role +
    r'\s+kind=(\S+)\s+sid=(\S+?)\s*\]',
    re.M,
)
matches = [m for m in reply_pat.finditer(text) if m.start() >= region_start]
if not matches:
    sys.exit(3)

chosen = next((m for m in matches if m.group(2) == want_sid), None)
if chosen is None:
    sys.stderr.write(f"recv.sh: sid mismatch (got {matches[0].group(2)!r}, expected {want_sid!r})\n")
    sys.exit(4)

kind = chosen.group(1)

# Body: lines after the chosen header, up to the TUI input-box rule that follows the reply.
# Match only the box-drawing rule (U+2500 '─'), never ascii '-', so a markdown horizontal
# rule inside the reply body is not mistaken for chrome and truncated.
out = []
for line in text[chosen.end():].splitlines():
    t = line.strip()
    if len(t) >= 10 and set(t) <= set("─"):
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
