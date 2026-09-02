#!/usr/bin/env python3

from pathlib import Path
import re
import sys


HEREDOC = re.compile(
    r"(?<!<)<<(?P<strip_tabs>-?)(?!<)\s*"
    r"(?P<quote>['\"]?)(?P<delimiter>[A-Za-z_][A-Za-z0-9_]*)(?P=quote)"
)
CONTROL_FLOW = {"if": "then", "elif": "then", "while": "do", "until": "do"}


def shell_word_at(line, index, word):
    end = index + len(word)
    return line.startswith(word, index) and (
        end == len(line) or line[end].isspace() or line[end] == ";"
    )


def line_state_after(line, state=None, arithmetic_depth=0):
    escaped = False
    heredocs = []
    index = 0
    while index < len(line):
        character = line[index]
        if escaped:
            escaped = False
        elif state == "'":
            if character == "'":
                state = None
        elif character == "\\":
            escaped = True
        elif state == '"':
            if character == '"':
                state = None
        elif character == "#" and (index == 0 or line[index - 1].isspace()):
            break
        elif line.startswith("$((", index):
            arithmetic_depth += 1
            index += 2
        elif line.startswith("((", index):
            arithmetic_depth += 1
            index += 1
        elif arithmetic_depth and line.startswith("))", index):
            arithmetic_depth -= 1
            index += 1
        elif character == "<" and not arithmetic_depth:
            match = HEREDOC.match(line, index)
            if match:
                heredocs.append(
                    (match.group("delimiter"), bool(match.group("strip_tabs")))
                )
                index = match.end() - 1
        elif character in ("'", '"'):
            state = character
        index += 1
    return state, arithmetic_depth, heredocs


def conditional_command(line, start=0):
    state = None
    escaped = False
    arithmetic_depth = 0
    control_terminator = None
    command_start = start == 0
    index = start

    while index < len(line):
        character = line[index]
        if escaped:
            escaped = False
        elif state == "'":
            if character == "'":
                state = None
        elif character == "\\":
            escaped = True
        elif state == '"':
            if character == '"':
                state = None
        elif character == "#" and (index == 0 or line[index - 1].isspace()):
            break
        elif character in ("'", '"'):
            state = character
        elif command_start and control_terminator and shell_word_at(
            line, index, control_terminator
        ):
            index += len(control_terminator) - 1
            control_terminator = None
        elif command_start and any(
            shell_word_at(line, index, word) for word in CONTROL_FLOW
        ):
            word = next(
                word for word in CONTROL_FLOW if shell_word_at(line, index, word)
            )
            control_terminator = CONTROL_FLOW[word]
            index += len(word) - 1
        elif line.startswith("$((", index):
            arithmetic_depth += 1
            command_start = False
            index += 2
        elif line.startswith("((", index):
            if command_start and not control_terminator:
                return index, "((", "))"
            arithmetic_depth += 1
            index += 1
        elif arithmetic_depth and line.startswith("))", index):
            arithmetic_depth -= 1
            index += 1
        elif not arithmetic_depth and line.startswith(("&&", "||"), index):
            command_start = True
            index += 1
        elif not arithmetic_depth and character == ";":
            command_start = True
        elif not character.isspace():
            if (
                command_start
                and not control_terminator
                and line.startswith("[[", index)
                and (index + 2 == len(line) or line[index + 2].isspace())
            ):
                return index, "[[", "]]"
            command_start = False
        index += 1

    return None


def unquoted_closing(line, start, closing, state=None):
    escaped = False
    index = start
    while index < len(line):
        character = line[index]
        if escaped:
            escaped = False
        elif state == "'":
            if character == "'":
                state = None
        elif character == "\\":
            escaped = True
        elif state == '"':
            if character == '"':
                state = None
        elif character in ("'", '"'):
            state = character
        elif line.startswith(closing, index):
            return index, state
        index += 1
    return -1, state


def find_violations(path):
    lines = path.read_text(encoding="utf-8").splitlines()
    violations = []
    heredocs = []
    quote_state = None
    arithmetic_depth = 0
    index = 0

    while index < len(lines):
        line = lines[index]
        if heredocs:
            delimiter, strip_tabs = heredocs[0]
            candidate = line.lstrip("\t") if strip_tabs else line
            if candidate == delimiter:
                heredocs.pop(0)
            index += 1
            continue

        if quote_state:
            quote_state, arithmetic_depth, _ = line_state_after(
                line, quote_state, arithmetic_depth
            )
            index += 1
            continue

        conditional = conditional_command(line)
        command_end = index
        scan_line = index
        while conditional:
            start_column, opening, closing = conditional
            conditional_line = scan_line
            command_end = scan_line
            condition_quote = None
            closing_column, condition_quote = unquoted_closing(
                lines[command_end], start_column + len(opening), closing
            )
            while closing_column < 0 and command_end + 1 < len(lines):
                command_end += 1
                closing_column, condition_quote = unquoted_closing(
                    lines[command_end], 0, closing, condition_quote
                )

            tail = ""
            if closing_column >= 0:
                tail = lines[command_end][closing_column + len(closing) :].strip()
            handled = tail.startswith(("||", "&&"))
            if tail == "\\" and command_end + 1 < len(lines):
                handled = lines[command_end + 1].lstrip().startswith(("||", "&&"))
            if not handled:
                violations.append((conditional_line + 1, opening, closing))

            if closing_column < 0:
                break
            scan_line = command_end
            scan_column = closing_column + len(closing)
            conditional = conditional_command(lines[scan_line], scan_column)

        if command_end > index:
            for command_line in lines[index : command_end + 1]:
                quote_state, arithmetic_depth, found_heredocs = line_state_after(
                    command_line, quote_state, arithmetic_depth
                )
                heredocs.extend(found_heredocs)
            index = command_end
        else:
            quote_state, arithmetic_depth, found_heredocs = line_state_after(
                line, quote_state, arithmetic_depth
            )
            heredocs.extend(found_heredocs)

        index += 1

    return violations


def scanned_files(tests_dir):
    # .bats files disappear in a later migration stage; their absence is fine.
    for path in sorted(tests_dir.rglob("*.bats")):
        if path.relative_to(tests_dir).parts[:2] == ("helpers", "bats-libs"):
            continue
        yield path
    # The bashunit DSL's ERR trap reproduces the same bash-3.2 quirk: a bare
    # mid-test [[ ]] or (( )) conditional is silently inert. Scan the whole
    # file, not only test_* bodies — helpers run in the same test context.
    yield from sorted(tests_dir.rglob("bashunit/*_test.sh"))
    # tests/helpers/*.bash is sourced into that same test context (e.g. via
    # `load 'helpers/common'`), so the identical quirk applies there. Only
    # the flat directory: helpers/bats-libs is vendored and excluded above
    # for *.bats, and this glob does not descend into it either.
    yield from sorted(tests_dir.glob("helpers/*.bash"))


def main(argv):
    tests_dir = Path(argv[1]) if len(argv) > 1 else Path("tests")
    violations = []
    for path in scanned_files(tests_dir):
        for line_number, opening, closing in find_violations(path):
            violations.append(
                f"{path}:{line_number}: bare {opening}...{closing} requires "
                "explicit status handling"
            )

    if violations:
        print("\n".join(violations))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
