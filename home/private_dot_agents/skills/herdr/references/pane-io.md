# Pane input and output

## Send keys

`pane send-text` types text without Enter. `pane send-keys` presses named keys. Key names are validated before any bytes are written; use lowercase logical names (`esc`, `ctrl+c`). `send-keys` preserves Shift in `shift+tab`.

## Read sources

- `visible` — current viewport.
- `recent` — recent scrollback as rendered, including soft wraps.
- `recent-unwrapped` — soft wraps joined; prefer it for logs and transcripts.
- `detection` — the plain-text snapshot used for agent detection.

`--format ansi` (or `--ansi`) returns a rendered ANSI snapshot, for when colors and styling are evidence.

`--lines` asks for more rows from the pane's screen and host scrollback. If a larger value does not reveal more of a completed response, the pane is probably on the terminal's alternate screen; those rows never enter host scrollback. Fallback, only after such a failed read: ask the agent to write its complete response as Markdown to a temp file and reply with the path, then read the file.

## Output and exit status

- `pane read` and `agent read` print text, not JSON.
- `pane send-text`, `pane send-keys`, and `pane run` print nothing on success.
- A CLI server error is JSON on stderr with exit status 1. A CLI syntax error exits with status 2.
