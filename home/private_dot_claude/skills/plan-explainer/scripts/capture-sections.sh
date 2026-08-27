#!/usr/bin/env bash
# Capture one screenshot per section of a local explainer page, so a whole
# page costs one command instead of three tool calls per section.
#
#   bash ~/.claude/skills/plan-explainer/scripts/capture-sections.sh <html-file> <out-dir>
#
# On success prints, on stdout, a manifest of "<section-id> <png-path>" lines —
# more than one line for a section taller than the viewport — then the
# page-level horizontal-overflow verdict. Every printed PNG still has to be
# read: this removes the repetition, never the looking.
#
# Exits nonzero, with a "capture-sections:" message on stderr, for: a wrong
# argument count, a missing html-file, an out-dir that cannot be created,
# agent-browser failing to open the page or to evaluate against it, zero
# <section> elements, and any section whose capture failed. A failed section
# does not stop the run — the remaining sections are still captured — so read
# stderr as well as the manifest.
#
# A section taller than MAX_SHOTS_PER_SECTION viewports is captured only down
# to that depth; the script says so on stderr and the tail goes unphotographed.

set -u

AB=(npx -y agent-browser)
VIEWPORT_STEP_RATIO=0.9   # overlap successive captures so nothing hides at a seam
MAX_SHOTS_PER_SECTION=4

die() { printf 'capture-sections: %s\n' "$1" >&2; exit 1; }

[ "$#" -eq 2 ] || die "usage: capture-sections.sh <html-file> <out-dir>"

html="$1"
out_dir="$2"

[ -f "$html" ] || die "no such file: $html"
mkdir -p "$out_dir" || die "cannot create $out_dir"

# agent-browser writes a relative screenshot path somewhere unpredictable.
case "$html" in /*) abs_html="$html" ;; *) abs_html="$PWD/$html" ;; esac
case "$out_dir" in /*) abs_out="$out_dir" ;; *) abs_out="$PWD/$out_dir" ;; esac

cleanup() { "${AB[@]}" close >/dev/null 2>&1 || true; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

# agent-browser keeps ONE javascript scope across every eval in a session, so a
# bare `const x` collides with the previous call's `x` and the whole expression
# fails. Every body below is wrapped in an IIFE for that reason.
# The result comes back JSON-encoded; unwrap the outer quotes. A crashed eval
# must not read as an empty answer, so the pipe's first status is checked.
ab_eval() {
  local out status
  out="$("${AB[@]}" eval "(() => { $1 })()" 2>/dev/null | tail -1 | sed -e 's/^"//' -e 's/"$//')"
  status="${PIPESTATUS[0]}"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$out"
}

"${AB[@]}" open "file://$abs_html" >/dev/null 2>&1 || die "agent-browser could not open $abs_html"

# Every section is captured. An authored id names its file; a section without
# one still gets captured under a positional name rather than silently skipped.
ids="$(ab_eval "
  const all = Array.from(document.querySelectorAll('section'));
  return all.map((s, i) => s.id || 'section-' + (i + 1)).join('|');
")" || die "agent-browser eval failed against $abs_html"

[ -n "$ids" ] || die "no <section> elements found in $abs_html"

fail=0
index=0
while IFS= read -r id; do
  index=$((index + 1))

  # One measurement per section: where it starts, how tall it is, how tall the window is.
  metrics="$(ab_eval "
    const all = Array.from(document.querySelectorAll('section'));
    const el = document.getElementById('$id') || all[$index - 1];
    if (!el) return 'missing';
    const r = el.getBoundingClientRect();
    return [Math.round(r.top + window.scrollY), Math.round(r.height), window.innerHeight].join(',');
  ")" || { printf 'capture-sections: eval failed measuring %s\n' "$id" >&2; fail=1; continue; }

  case "$metrics" in
    missing|"") printf 'capture-sections: skipped %s (not found)\n' "$id" >&2; fail=1; continue ;;
  esac

  top="${metrics%%,*}"
  rest="${metrics#*,}"
  height="${rest%%,*}"
  view="${rest##*,}"

  needed="$(awk -v h="$height" -v v="$view" 'BEGIN { n = (v > 0) ? int((h + v - 1) / v) : 1; if (n < 1) n = 1; print n }')"
  if [ "$needed" -gt "$MAX_SHOTS_PER_SECTION" ]; then
    printf 'capture-sections: %s spans %d viewports, capped at %d — its tail is not captured\n' \
      "$id" "$needed" "$MAX_SHOTS_PER_SECTION" >&2
    shots="$MAX_SHOTS_PER_SECTION"
  else
    shots="$needed"
  fi

  shot=0
  while [ "$shot" -lt "$shots" ]; do
    offset="$(awk -v t="$top" -v v="$view" -v i="$shot" -v r="$VIEWPORT_STEP_RATIO" \
      'BEGIN { print int(t + i * v * r) }')"
    ab_eval "window.scrollTo(0, $offset); return 'ok';" >/dev/null || true

    if [ "$shots" -eq 1 ]; then
      png="$abs_out/$id.png"
    else
      png="$abs_out/$id-$((shot + 1)).png"
    fi

    if "${AB[@]}" screenshot "$png" >/dev/null 2>&1; then
      printf '%s %s\n' "$id" "$png"
    else
      printf 'capture-sections: capture failed for %s (shot %d of %d)\n' "$id" "$((shot + 1))" "$shots" >&2
      fail=1
    fi
    shot=$((shot + 1))
  done
done < <(printf '%s\n' "$ids" | tr '|' '\n')   # trailing newline: read drops a final unterminated line

overflow="$(ab_eval "
  const el = document.scrollingElement;
  return el.scrollWidth <= el.clientWidth ? 'body-width-ok' : 'HORIZONTAL-OVERFLOW';
")" || overflow="unknown (eval failed)"
printf 'overflow: %s\n' "$overflow"

[ "$fail" -eq 0 ] || exit 1
