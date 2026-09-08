"""Resolve one arm of a style A/B run into the exact text the run will inject.

An arm is whatever the run puts in front of the model as its appended system
prompt. Three routes reach one: the empty control, a git ref, and a file path
(including the working tree). Every route returns the same record, so the report
can name what it measured without knowing which route produced it.

A ref moves and a path is mutable, so the record carries the resolved commit id
and a SHA-256 of the bytes rather than the spec it was asked for (KTD4).
"""

import hashlib
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

MEASURED_RELPATH = "home/.chezmoitemplates/writing-style.md"

# The measured file is a chezmoi template partial: four adapters pull it in with
# `includeTemplate`, which executes it. It carries no Go template action today,
# which is why reading it directly gives the rule text the adapters deploy. If
# one ever appears, the run would measure template source instead of prose.
TEMPLATE_ACTION = re.compile(r"\{\{|\}\}")

# A stdlib proxy for token count: words plus standalone punctuation. Its absolute
# value is not a real tokenizer's and must not be compared to one. It exists so a
# rule set that grows without changing behaviour is visible across arms of the
# same run, which is the only comparison R11 asks for.
TOKEN_PROXY = re.compile(r"\w+|[^\w\s]")


class UnrenderedTemplate(Exception):
    """The resolved arm still carries a Go template action."""


class ArmUnresolvable(Exception):
    """The spec names neither a readable path nor a git ref carrying the file."""


@dataclass(frozen=True)
class Arm:
    spec: str
    kind: str
    text: str
    sha256: str
    tokens: int
    commit: str | None
    source: str


def _git(repo_root, *args):
    return subprocess.run(
        ["git", *args], cwd=str(repo_root),
        capture_output=True, text=True, check=True,
    ).stdout


def _build(spec, kind, text, source, commit=None):
    if TEMPLATE_ACTION.search(text):
        raise UnrenderedTemplate(
            f"{source} still carries a Go template action; the run would measure "
            f"template source rather than the prose a reader sees"
        )
    encoded = text.encode("utf-8")
    return Arm(
        spec=spec,
        kind=kind,
        text=text,
        sha256=hashlib.sha256(encoded).hexdigest(),
        tokens=len(TOKEN_PROXY.findall(text)),
        commit=commit,
        source=source,
    )


def resolve(spec, repo_root):
    """Resolve `spec` into an Arm.

    `base` is the empty control. `worktree` is the measured file as it stands.
    An existing path is read as-is. Anything else is treated as a git ref and
    read at `MEASURED_RELPATH`.
    """
    repo_root = Path(repo_root)

    if spec == "base":
        return _build(spec, "base", "", "the empty control arm")

    if spec == "worktree":
        target = repo_root / MEASURED_RELPATH
        return _build(spec, "worktree", target.read_text(), f"{MEASURED_RELPATH} (working tree)")

    candidate = Path(spec)
    if candidate.exists() and candidate.is_file():
        return _build(spec, "path", candidate.read_text(), str(candidate))

    try:
        text = _git(repo_root, "show", f"{spec}:{MEASURED_RELPATH}")
        commit = _git(repo_root, "rev-parse", spec).strip()
    except subprocess.CalledProcessError as error:
        raise ArmUnresolvable(
            f"{spec!r} is not a readable file and not a git ref carrying "
            f"{MEASURED_RELPATH}: {error.stderr.strip()}"
        ) from error
    return _build(spec, "ref", text, f"{MEASURED_RELPATH} at {spec}", commit=commit)


def identical(baseline, candidate):
    """Two arms that inject the same bytes measure nothing (R5)."""
    return baseline.sha256 == candidate.sha256
