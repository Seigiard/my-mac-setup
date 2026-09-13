#!/usr/bin/env python3
"""Temporary GitHub issue migration importer.

This tool is intentionally scoped to the local-to-GitHub tracker migration. It
uses hidden legacy markers to recover creates that reached GitHub before local
state was persisted, and it refuses to overwrite unexpected target changes.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple


MARKER = re.compile(r"<!-- my-mac-setup-issue-migration:([^ ]+) -->")
PLACEHOLDER = re.compile(r"\{\{(source|target):([^}]+)\}\}")
INTERRUPTED = 75

PILOT_SOURCES = (
    {
        "id": "2026-08-17-001",
        "path": "docs/issues/2026-08-17-001-herdr-event-subscription-supervisor.md",
        "labels": ["enhancement", "ready-for-human"],
        "coverage": ["open", "idea", "herdr", "low", "parent-plan", "unicode"],
    },
    {
        "id": "2026-08-18-001",
        "path": "docs/issues/2026-08-18-001-launch-time-permission-mode-for-child-agents.md",
        "labels": ["enhancement", "ready-for-agent"],
        "coverage": ["agent-platform", "high"],
    },
    {
        "id": "2026-08-18-002",
        "path": "docs/issues/2026-08-18-002-sandbox-a-child-agents-filesystem-access.md",
        "labels": ["enhancement", "ready-for-agent"],
        "coverage": ["agent-platform", "active-to-active"],
        "relations": [
            {
                "source_text": "`docs/issues/2026-08-18-001-launch-time-permission-mode-for-child-agents.md`",
                "kind": "target",
                "value": "2026-08-18-001",
            }
        ],
    },
    {
        "id": "2026-08-18-019",
        "path": "docs/issues/2026-08-18-019-add-manual-agentbox-sessions-to-herdr.md",
        "labels": ["enhancement", "ready-for-agent"],
        "coverage": ["follow-up", "multiple-active-links"],
        "relations": [
            {
                "source_text": "`docs/issues/2026-08-18-001-launch-time-permission-mode-for-child-agents.md`",
                "kind": "target",
                "value": "2026-08-18-001",
            },
            {
                "source_text": "`docs/issues/2026-08-18-002-sandbox-a-child-agents-filesystem-access.md`",
                "kind": "target",
                "value": "2026-08-18-002",
                "occurrences": 2,
            },
        ],
    },
    {
        "id": "2026-08-18-024",
        "path": "docs/issues/2026-08-18-024-palette-focus-sleeps-live-trial.md",
        "labels": ["bug", "ready-for-agent"],
        "coverage": ["bug", "command-palette"],
    },
    {
        "id": "2026-09-05-007",
        "path": "docs/issues/2026-09-05-007-pane-label-herdr-stub-omits-four-snapshot-keys-the-real-binary-returns.md",
        "labels": ["enhancement", "ready-for-agent"],
        "coverage": ["testing-ci", "code-fence"],
    },
    {
        "id": "2026-09-06-007",
        "path": "docs/issues/2026-09-06-007-review-time-tautology-check-to-replace-the-retired-write-path-gate.md",
        "labels": ["enhancement", "ready-for-agent"],
        "coverage": ["se-pipeline", "high", "largest-body", "largest-tag-set", "active-to-terminal"],
        "relations": [
            {
                "source_text": "`2026-09-12-001`",
                "kind": "source",
                "value": "docs/issues/2026-09-12-001-select-external-leg-models-by-complexity-and-effort.md",
            }
        ],
    },
    {
        "id": "2026-09-12-001",
        "path": "docs/issues/2026-09-12-001-select-external-leg-models-by-complexity-and-effort.md",
        "labels": ["enhancement", "ready-for-agent"],
        "coverage": ["done", "completed-state-reason", "medium"],
    },
    {
        "id": "2026-08-26-002",
        "path": "docs/issues/2026-08-26-002-herdr-child-launch-failure-cleanup-doesn-t-report-sibling-pane-tab-state.md",
        "labels": ["enhancement", "wontfix"],
        "coverage": ["wontfix", "not-planned-state-reason"],
    },
)

SYNTHETIC_IN_PROGRESS = {
    "id": "2026-09-13-999",
    "path": "synthetic/pilot-in-progress.md",
    "title": "Pilot synthetic in-progress chore",
    "short_description": "A synthetic record proves assignment-based in-progress migration without changing the source corpus.",
    "type": "chore",
    "category": "agent-platform",
    "tags": ["pilot", "in-progress", "unicode"],
    "status": "in-progress",
    "priority": "medium",
    "body": """## Why this exists

The local corpus has no in-progress record, so this reviewed synthetic case
proves that assignment, rather than a status label, carries the claim. Привет.

## Scope

Keep this fixture limited to the private pilot.

```sh
printf '%s\\n' 'resume safely'
```

It also references 2026-09-05-007 to exercise repair from a synthetic body.

## Open decisions

None.
""",
    "labels": ["enhancement", "ready-for-agent"],
    "assignees": ["Seigiard"],
    "coverage": ["in-progress", "chore", "assignment", "synthetic", "unicode", "code-fence"],
    "relations": [
        {
            "source_text": "2026-09-05-007",
            "kind": "target",
            "value": "2026-09-05-007",
        }
    ],
}

LABELS = (
    {"name": "bug", "color": "d73a4a", "description": "Something isn't working"},
    {"name": "enhancement", "color": "a2eeef", "description": "New feature or request"},
    {"name": "ready-for-agent", "color": "0E8A16", "description": "Fully specified, ready for an AFK agent"},
    {"name": "ready-for-human", "color": "FBCA04", "description": "Requires human judgment or access"},
    {"name": "wontfix", "color": "ffffff", "description": "This will not be worked on"},
)


class MigrationError(RuntimeError):
    pass


@dataclass(frozen=True)
class ExpectedIssue:
    title: str
    body: str
    labels: Tuple[str, ...]
    assignees: Tuple[str, ...]
    state: str
    state_reason: Optional[str]


def compact_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def normalize_body(value: str) -> str:
    return value.replace("\r\n", "\n").rstrip() + "\n"


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".%s-" % path.name, dir=str(path.parent))
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def migration_lock(state_path: Path, repository: str) -> Iterable[None]:
    state_path.parent.mkdir(parents=True, exist_ok=True)
    lock_name = "my-mac-setup-github-issue-migration-%s.lock" % sha256_bytes(repository.casefold().encode())[:16]
    lock_path = Path(tempfile.gettempdir()) / lock_name
    descriptor = os.open(str(lock_path), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise MigrationError("another importer holds %s" % lock_path) from error
        yield
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def run_json(command: Sequence[str], input_value: Optional[Any] = None) -> Any:
    result = subprocess.run(
        list(command),
        input=None if input_value is None else compact_json(input_value),
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "command failed"
        raise MigrationError("%s: %s" % (" ".join(command), detail))
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise MigrationError("%s returned invalid JSON" % " ".join(command)) from error


def gh_api(endpoint: str, method: str = "GET", payload: Optional[Any] = None) -> Any:
    command = ["gh", "api"]
    if method != "GET":
        command.extend(["--method", method])
    command.append(endpoint)
    if payload is not None:
        command.extend(["--input", "-"])
    return run_json(command, payload)


def paginated(endpoint: str) -> List[Dict[str, Any]]:
    separator = "&" if "?" in endpoint else "?"
    output: List[Dict[str, Any]] = []
    page = 1
    while True:
        values = gh_api("%s%sper_page=100&page=%d" % (endpoint, separator, page))
        if not isinstance(values, list):
            raise MigrationError("expected a list from %s" % endpoint)
        output.extend(values)
        if len(values) < 100:
            return output
        page += 1


def git_blob(commit: str, path: str) -> bytes:
    result = subprocess.run(
        ["git", "show", "%s:%s" % (commit, path)],
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise MigrationError("cannot read %s at %s: %s" % (path, commit, result.stderr.decode("utf-8", "replace").strip()))
    return result.stdout


def split_document(contents: bytes) -> Tuple[Dict[str, Any], str]:
    if not contents.startswith(b"---\n"):
        raise MigrationError("source document has no frontmatter")
    boundary = contents.find(b"\n---\n", 4)
    if boundary < 0:
        raise MigrationError("source document has malformed frontmatter")
    metadata: Dict[str, Any] = {}
    for line in contents[4:boundary].decode("utf-8").splitlines():
        key, value = line.split(": ", 1)
        try:
            metadata[key] = json.loads(value)
        except json.JSONDecodeError:
            metadata[key] = value
    return metadata, contents[boundary + 5 :].decode("utf-8")


def source_link_placeholder(path: str) -> str:
    return "{{source:%s}}" % path


def transform_body(
    source_id: str,
    source_path: str,
    metadata: Mapping[str, Any],
    body: str,
    relations: Sequence[Mapping[str, str]],
    source_commit: str,
    provenance_url: Optional[str] = None,
) -> str:
    transformed = body
    for relation in relations:
        source_text = relation["source_text"]
        occurrences = relation.get("occurrences", 1)
        if transformed.count(source_text) != occurrences:
            raise MigrationError(
                "%s must contain declared relation %d time(s): %s" % (source_id, occurrences, source_text)
            )
        destination = "{{%s:%s}}" % (relation["kind"], relation["value"])
        link_text = "legacy issue `%s`" % (
            relation["value"] if relation["kind"] == "target" else Path(relation["value"]).name[:14]
        )
        transformed = transformed.replace(source_text, "[%s](%s)" % (link_text, destination))
    parts = [metadata["short_description"]]
    parent = metadata.get("parent-plan")
    if parent:
        parts.append("Parent plan: [`%s`](%s)" % (parent, source_link_placeholder(parent)))
    parts.append(transformed.strip())
    parts.append(
        "---\nLegacy source: [`%s`](%s)%s.\n<!-- my-mac-setup-issue-migration:%s -->"
        % (
            source_id,
            provenance_url or source_link_placeholder(source_path),
            " at `%s`" % source_commit if provenance_url is None else " (reviewed synthetic pilot fixture)",
            source_id,
        )
    )
    return normalize_body("\n\n".join(parts))


def desired_state(status: str) -> Tuple[str, Optional[str]]:
    if status in ("open", "in-progress"):
        return "open", None
    if status == "done":
        return "closed", "completed"
    if status == "wontfix":
        return "closed", "not_planned"
    raise MigrationError("unsupported source status %s" % status)


def build_pilot_manifest(source_repository: str, source_commit: str, target_repository: str) -> Dict[str, Any]:
    entries = []
    for specification in PILOT_SOURCES:
        contents = git_blob(source_commit, specification["path"])
        metadata, body = split_document(contents)
        state, state_reason = desired_state(metadata["status"])
        relations = specification.get("relations", [])
        entries.append(
            {
                "source": {
                    "id": specification["id"],
                    "path": specification["path"],
                    "sha256": sha256_bytes(contents),
                    "status": metadata["status"],
                    "type": metadata["type"],
                    "category": metadata["category"],
                    "priority": metadata["priority"],
                    "tags": metadata["tags"],
                    "parent_plan": metadata.get("parent-plan"),
                    "synthetic": False,
                },
                "target": {
                    "title": metadata["title"],
                    "body_template": transform_body(
                        specification["id"],
                        specification["path"],
                        metadata,
                        body,
                        relations,
                        source_commit,
                    ),
                    "labels": specification["labels"],
                    "assignees": [],
                    "state": state,
                    "state_reason": state_reason,
                },
                "relations": relations,
                "coverage": specification["coverage"],
            }
        )

    synthetic = dict(SYNTHETIC_IN_PROGRESS)
    synthetic_source = {
        key: synthetic[key]
        for key in ("id", "path", "title", "short_description", "type", "category", "tags", "status", "priority", "body")
    }
    synthetic_bytes = (compact_json(synthetic_source) + "\n").encode("utf-8")
    state, state_reason = desired_state(synthetic["status"])
    entries.append(
        {
            "source": {
                "id": synthetic["id"],
                "path": synthetic["path"],
                "sha256": sha256_bytes(synthetic_bytes),
                "status": synthetic["status"],
                "type": synthetic["type"],
                "category": synthetic["category"],
                "priority": synthetic["priority"],
                "tags": synthetic["tags"],
                "parent_plan": None,
                "synthetic": True,
            },
            "target": {
                "title": synthetic["title"],
                "body_template": transform_body(
                    synthetic["id"],
                    synthetic["path"],
                    synthetic,
                    synthetic["body"],
                    synthetic["relations"],
                    source_commit,
                    provenance_url="https://github.com/%s/issues/206" % source_repository,
                ),
                "labels": synthetic["labels"],
                "assignees": synthetic["assignees"],
                "state": state,
                "state_reason": state_reason,
            },
            "relations": synthetic["relations"],
            "coverage": synthetic["coverage"],
        }
    )
    return {
        "schema_version": 1,
        "manifest_id": "github-issues-private-pilot-v1",
        "source_repository": source_repository,
        "source_commit": source_commit,
        "target_repository": target_repository,
        "target_policy": {
            "private": True,
            "require_empty_on_first_apply": True,
            "require_push_permission": True,
        },
        "labels": list(LABELS),
        "coverage": {
            "statuses": ["open", "in-progress", "done", "wontfix"],
            "types": ["bug", "chore", "follow-up", "idea"],
            "categories": ["agent-platform", "command-palette", "herdr", "se-pipeline", "testing-ci"],
            "priorities": ["high", "low", "medium"],
            "special": [
                "parent-plan",
                "active-to-active",
                "active-to-terminal",
                "unicode",
                "code-fence",
                "largest-body",
                "largest-tag-set",
                "largest-planned-label-set",
            ],
        },
        "entries": entries,
    }


def load_manifest(path: Path) -> Tuple[Dict[str, Any], str]:
    contents = path.read_bytes()
    try:
        manifest = json.loads(contents)
    except json.JSONDecodeError as error:
        raise MigrationError("invalid manifest JSON: %s" % error) from error
    if manifest.get("schema_version") != 1:
        raise MigrationError("unsupported manifest schema")
    entries = manifest.get("entries")
    if not isinstance(entries, list) or not entries:
        raise MigrationError("manifest entries must be a non-empty list")
    identifiers = [entry.get("source", {}).get("id") for entry in entries]
    if any(not value for value in identifiers) or len(set(identifiers)) != len(identifiers):
        raise MigrationError("manifest source IDs must be unique")
    known = set(identifiers)
    for entry in entries:
        source_id = entry["source"]["id"]
        target = entry.get("target", {})
        if len(target.get("labels", [])) != 2:
            raise MigrationError("%s must have exactly two planned labels" % source_id)
        body = target.get("body_template", "")
        markers = MARKER.findall(body)
        if markers != [source_id]:
            raise MigrationError("%s must contain exactly one matching marker" % source_id)
        for kind, value in PLACEHOLDER.findall(body):
            if kind == "target" and value not in known:
                raise MigrationError("%s targets unknown source %s" % (source_id, value))
        for relation in entry.get("relations", []):
            if relation.get("kind") not in ("source", "target") or not relation.get("source_text") or not relation.get("value"):
                raise MigrationError("%s has an invalid relation" % source_id)
            if not isinstance(relation.get("occurrences", 1), int) or relation.get("occurrences", 1) < 1:
                raise MigrationError("%s has an invalid relation occurrence count" % source_id)
            if relation["kind"] == "target" and relation["value"] not in known:
                raise MigrationError("%s targets unknown source %s" % (source_id, relation["value"]))
    return manifest, sha256_bytes(contents)


def render_body(manifest: Mapping[str, Any], entry: Mapping[str, Any], mappings: Mapping[str, Any], final: bool) -> str:
    source_repo = manifest["source_repository"]
    source_commit = manifest["source_commit"]

    def replace(match: re.Match[str]) -> str:
        kind, value = match.groups()
        if kind == "source":
            return "https://github.com/%s/blob/%s/%s" % (source_repo, source_commit, value)
        if final:
            mapping = mappings.get(value)
            if not mapping:
                raise MigrationError("target mapping unavailable for %s" % value)
            return mapping["url"]
        return value

    return normalize_body(PLACEHOLDER.sub(replace, entry["target"]["body_template"]))


def expected_issue(manifest: Mapping[str, Any], entry: Mapping[str, Any], mappings: Mapping[str, Any], final: bool, desired: bool = True) -> ExpectedIssue:
    target = entry["target"]
    state = target["state"] if desired else "open"
    state_reason = target.get("state_reason") if desired else None
    return ExpectedIssue(
        title=target["title"],
        body=render_body(manifest, entry, mappings, final),
        labels=tuple(sorted(target["labels"])),
        assignees=tuple(sorted(target.get("assignees", []))),
        state=state,
        state_reason=state_reason,
    )


def actual_issue(issue: Mapping[str, Any]) -> ExpectedIssue:
    return ExpectedIssue(
        title=issue["title"],
        body=normalize_body(issue.get("body") or ""),
        labels=tuple(sorted(label["name"] for label in issue.get("labels", []))),
        assignees=tuple(sorted(assignee["login"] for assignee in issue.get("assignees", []))),
        state=issue["state"],
        state_reason=issue.get("state_reason"),
    )


def describe_mismatch(observed: ExpectedIssue, allowed: Iterable[ExpectedIssue]) -> str:
    fields = ("title", "body", "labels", "assignees", "state", "state_reason")
    closest = min(allowed, key=lambda item: sum(getattr(item, field) != getattr(observed, field) for field in fields))
    differences = []
    for field in fields:
        if getattr(observed, field) != getattr(closest, field):
            if field == "body":
                differences.append("body_sha256=%s expected=%s" % (sha256_bytes(observed.body.encode()), sha256_bytes(closest.body.encode())))
            else:
                differences.append("%s=%r expected=%r" % (field, getattr(observed, field), getattr(closest, field)))
    return "; ".join(differences)


def extract_markers(issue: Mapping[str, Any]) -> List[str]:
    return MARKER.findall(issue.get("body") or "")


def fetch_target_issues(repository: str) -> List[Dict[str, Any]]:
    return [issue for issue in paginated("repos/%s/issues?state=all&" % repository) if "pull_request" not in issue]


def validate_target(
    repository: str,
    manifest: Mapping[str, Any],
    remote_issues: Sequence[Mapping[str, Any]],
    first_apply: bool,
) -> None:
    if repository != manifest.get("target_repository"):
        raise MigrationError("manifest targets %s, not %s" % (manifest.get("target_repository"), repository))
    metadata = gh_api("repos/%s" % repository)
    policy = manifest.get("target_policy", {})
    if metadata.get("full_name", "").casefold() != repository.casefold():
        raise MigrationError("GitHub resolved an unexpected target repository")
    if bool(metadata.get("private")) != bool(policy.get("private")):
        raise MigrationError("target repository privacy does not match the manifest")
    if not metadata.get("has_issues"):
        raise MigrationError("target repository does not have Issues enabled")
    if metadata.get("archived"):
        raise MigrationError("target repository is archived")
    permissions = metadata.get("permissions", {})
    if policy.get("require_push_permission") and not (permissions.get("push") or permissions.get("maintain") or permissions.get("admin")):
        raise MigrationError("authenticated identity lacks push permission")
    if first_apply and policy.get("require_empty_on_first_apply") and remote_issues:
        raise MigrationError("target repository is not empty on first apply")

    eligible_assignees = {value["login"] for value in paginated("repos/%s/assignees?" % repository)}
    planned_assignees = {
        assignee
        for entry in manifest["entries"]
        for assignee in entry["target"].get("assignees", [])
    }
    unavailable = sorted(planned_assignees - eligible_assignees)
    if unavailable:
        raise MigrationError("target cannot assign: %s" % ", ".join(unavailable))


def issue_by_number(repository: str, number: int) -> Dict[str, Any]:
    value = gh_api("repos/%s/issues/%d" % (repository, number))
    if "pull_request" in value:
        raise MigrationError("target #%d is a pull request" % number)
    return value


def load_state(path: Path, repository: str, manifest_digest: str) -> Dict[str, Any]:
    if not path.exists():
        return {
            "schema_version": 1,
            "target_repository": repository,
            "manifest_sha256": manifest_digest,
            "complete": False,
            "issues": {},
        }
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise MigrationError("cannot read state: %s" % error) from error
    if state.get("schema_version") != 1:
        raise MigrationError("unsupported state schema")
    if state.get("target_repository") != repository:
        raise MigrationError("state targets %s, not %s" % (state.get("target_repository"), repository))
    if state.get("manifest_sha256") != manifest_digest:
        raise MigrationError("state manifest digest does not match")
    return state


def reconcile_remote(
    manifest: Mapping[str, Any],
    state: Dict[str, Any],
    remote_issues: Sequence[Mapping[str, Any]],
) -> Tuple[Dict[str, Dict[str, Any]], int]:
    entries = {entry["source"]["id"]: entry for entry in manifest["entries"]}
    remote_by_marker: Dict[str, List[Mapping[str, Any]]] = {}
    for issue in remote_issues:
        markers = extract_markers(issue)
        if len(markers) > 1:
            raise MigrationError("target #%s contains duplicate migration markers" % issue["number"])
        if markers:
            remote_by_marker.setdefault(markers[0], []).append(issue)
    for source_id, issues in remote_by_marker.items():
        if source_id not in entries:
            raise MigrationError("target contains unknown migration marker %s" % source_id)
        if len(issues) != 1:
            raise MigrationError("%s has %d target issues" % (source_id, len(issues)))

    recovered = 0
    mappings = state.setdefault("issues", {})
    for source_id, issues in remote_by_marker.items():
        issue = issues[0]
        existing = mappings.get(source_id)
        identity = {"number": issue["number"], "url": issue["html_url"], "node_id": issue["node_id"]}
        if existing and existing != identity:
            raise MigrationError("state identity differs from GitHub for %s" % source_id)
        if not existing:
            mappings[source_id] = identity
            recovered += 1
    for source_id, identity in mappings.items():
        issues = remote_by_marker.get(source_id, [])
        if not issues or issues[0]["number"] != identity["number"]:
            raise MigrationError("state target is missing for %s" % source_id)
    return {source_id: issues[0] for source_id, issues in remote_by_marker.items()}, recovered


def known_representations(
    manifest: Mapping[str, Any],
    entry: Mapping[str, Any],
    mappings: Mapping[str, Any],
    complete: bool,
) -> List[ExpectedIssue]:
    target = entry["target"]
    values = [expected_issue(manifest, entry, mappings, final=False, desired=True)]
    if target["state"] == "closed" and not complete:
        values.append(expected_issue(manifest, entry, mappings, final=False, desired=False))
    if len(mappings) == len(manifest["entries"]):
        values.append(expected_issue(manifest, entry, mappings, final=True, desired=True))
    if complete:
        values = [expected_issue(manifest, entry, mappings, final=True, desired=True)]
    unique: List[ExpectedIssue] = []
    for value in values:
        if value not in unique:
            unique.append(value)
    return unique


def preflight_remote(manifest: Mapping[str, Any], state: Mapping[str, Any], remote_by_marker: Mapping[str, Mapping[str, Any]]) -> None:
    entries = {entry["source"]["id"]: entry for entry in manifest["entries"]}
    for source_id, issue in remote_by_marker.items():
        observed = actual_issue(issue)
        allowed = known_representations(manifest, entries[source_id], state["issues"], bool(state.get("complete")))
        if observed not in allowed:
            raise MigrationError("DRIFT source=%s target=#%s phase=preflight %s" % (source_id, issue["number"], describe_mismatch(observed, allowed)))


def ensure_labels(repository: str, manifest: Mapping[str, Any]) -> int:
    existing = {label["name"]: label for label in paginated("repos/%s/labels?" % repository)}
    created = 0
    for expected in manifest["labels"]:
        observed = existing.get(expected["name"])
        if observed:
            if observed["color"].lower() != expected["color"].lower() or (observed.get("description") or "") != expected["description"]:
                raise MigrationError("DRIFT label=%s" % expected["name"])
            continue
        gh_api("repos/%s/labels" % repository, "POST", expected)
        readback = gh_api("repos/%s/labels/%s" % (repository, expected["name"]))
        if readback["color"].lower() != expected["color"].lower() or (readback.get("description") or "") != expected["description"]:
            raise MigrationError("label read-back mismatch for %s" % expected["name"])
        created += 1
    return created


def verify_label_definitions(repository: str, manifest: Mapping[str, Any]) -> None:
    observed = {label["name"]: label for label in paginated("repos/%s/labels?" % repository)}
    for expected in manifest["labels"]:
        actual = observed.get(expected["name"])
        if not actual:
            raise MigrationError("label disappeared: %s" % expected["name"])
        if actual["color"].lower() != expected["color"].lower() or (actual.get("description") or "") != expected["description"]:
            raise MigrationError("DRIFT label=%s" % expected["name"])


def create_issue(repository: str, expected: ExpectedIssue) -> Dict[str, Any]:
    payload = {
        "title": expected.title,
        "body": expected.body,
        "labels": list(expected.labels),
        "assignees": list(expected.assignees),
    }
    created = gh_api("repos/%s/issues" % repository, "POST", payload)
    return issue_by_number(repository, created["number"])


def patch_issue(repository: str, number: int, payload: Mapping[str, Any]) -> Dict[str, Any]:
    gh_api("repos/%s/issues/%d" % (repository, number), "PATCH", payload)
    return issue_by_number(repository, number)


def require_exact(source_id: str, issue: Mapping[str, Any], expected: ExpectedIssue, phase: str) -> None:
    observed = actual_issue(issue)
    if observed != expected:
        raise MigrationError(
            "READBACK source=%s target=#%s phase=%s %s"
            % (source_id, issue["number"], phase, describe_mismatch(observed, [expected]))
        )


def apply_manifest(manifest_path: Path, state_path: Path, repository: str, interrupt_after_create: Optional[int]) -> int:
    manifest, manifest_digest = load_manifest(manifest_path)
    first_apply = not state_path.exists()
    state = load_state(state_path, repository, manifest_digest)
    remote_issues = fetch_target_issues(repository)
    validate_target(repository, manifest, remote_issues, first_apply)
    remote_by_marker, recovered = reconcile_remote(manifest, state, remote_issues)
    preflight_remote(manifest, state, remote_by_marker)
    if first_apply or recovered:
        atomic_write_json(state_path, state)

    labels_created = ensure_labels(repository, manifest)
    created_count = 0
    closed_count = 0
    repaired_count = 0

    for entry in manifest["entries"]:
        source_id = entry["source"]["id"]
        issue = remote_by_marker.get(source_id)
        if issue is None:
            fresh_matches = [
                candidate
                for candidate in fetch_target_issues(repository)
                if extract_markers(candidate) == [source_id]
            ]
            if fresh_matches:
                raise MigrationError("target for %s appeared after preflight; restart to reconcile" % source_id)
            initial = expected_issue(manifest, entry, state["issues"], final=False, desired=False)
            issue = create_issue(repository, initial)
            require_exact(source_id, issue, initial, "create")
            created_count += 1
            remote_by_marker[source_id] = issue
            identity = {"number": issue["number"], "url": issue["html_url"], "node_id": issue["node_id"]}
            if interrupt_after_create == created_count:
                print(compact_json({"event": "intentional-interruption", "source_id": source_id, "target": identity}), file=sys.stderr)
                return INTERRUPTED
            state["issues"][source_id] = identity
            atomic_write_json(state_path, state)

        target = entry["target"]
        if target["state"] == "closed" and issue["state"] == "open":
            issue = issue_by_number(repository, issue["number"])
            expected_open = expected_issue(manifest, entry, state["issues"], final=False, desired=False)
            require_exact(source_id, issue, expected_open, "before-close")
            issue = patch_issue(
                repository,
                issue["number"],
                {"state": "closed", "state_reason": target["state_reason"]},
            )
            expected_closed = expected_issue(manifest, entry, state["issues"], final=False, desired=True)
            require_exact(source_id, issue, expected_closed, "close")
            remote_by_marker[source_id] = issue
            closed_count += 1

    if len(state["issues"]) != len(manifest["entries"]):
        raise MigrationError("not all target mappings were persisted")

    for entry in manifest["entries"]:
        source_id = entry["source"]["id"]
        issue = issue_by_number(repository, remote_by_marker[source_id]["number"])
        final = expected_issue(manifest, entry, state["issues"], final=True, desired=True)
        observed = actual_issue(issue)
        if observed == final:
            continue
        initial = expected_issue(manifest, entry, state["issues"], final=False, desired=True)
        if observed != initial:
            raise MigrationError("DRIFT source=%s target=#%s phase=repair %s" % (source_id, issue["number"], describe_mismatch(observed, [initial, final])))
        issue = patch_issue(repository, issue["number"], {"body": final.body})
        require_exact(source_id, issue, final, "repair")
        remote_by_marker[source_id] = issue
        repaired_count += 1

    final_issues = fetch_target_issues(repository)
    final_by_marker, final_recovered = reconcile_remote(manifest, state, final_issues)
    if final_recovered:
        raise MigrationError("unexpected target recovery during final verification")
    if manifest.get("target_policy", {}).get("require_empty_on_first_apply"):
        unmarked = [issue["number"] for issue in final_issues if not extract_markers(issue)]
        if unmarked:
            raise MigrationError("unexpected unmarked target issues: %s" % unmarked)
    for entry in manifest["entries"]:
        source_id = entry["source"]["id"]
        fresh = final_by_marker[source_id]
        require_exact(source_id, fresh, expected_issue(manifest, entry, state["issues"], final=True, desired=True), "complete")
    verify_label_definitions(repository, manifest)

    was_complete = bool(state.get("complete"))
    state["complete"] = True
    atomic_write_json(state_path, state)
    mutations = labels_created + created_count + closed_count + repaired_count
    result = {
        "result": "noop" if was_complete and mutations == 0 and recovered == 0 else "complete",
        "repository": repository,
        "labels_created": labels_created,
        "issues_created": created_count,
        "issues_recovered": recovered,
        "issues_closed": closed_count,
        "bodies_repaired": repaired_count,
        "mutations": mutations,
    }
    print(compact_json(result))
    return 0


def dry_run(manifest_path: Path, repository: str) -> int:
    manifest, digest = load_manifest(manifest_path)
    if repository != manifest.get("target_repository"):
        raise MigrationError("manifest targets %s, not %s" % (manifest.get("target_repository"), repository))
    requests: List[Dict[str, Any]] = [
        {"operation": "validate-target", "method": "GET", "path": "repos/%s" % repository},
        {"operation": "discover-targets", "method": "GET-paginated", "path": "repos/%s/issues?state=all" % repository},
        {"operation": "validate-assignees", "method": "GET-paginated", "path": "repos/%s/assignees" % repository},
        {"operation": "inspect-labels", "method": "GET-paginated", "path": "repos/%s/labels" % repository},
    ]
    for label in manifest["labels"]:
        requests.append({"operation": "ensure-label", "method": "POST-if-missing", "path": "repos/%s/labels" % repository, "payload": label})
        requests.append(
            {
                "operation": "read-back-created-label",
                "method": "GET-if-created",
                "path": "repos/%s/labels/%s" % (repository, label["name"]),
            }
        )
    for entry in manifest["entries"]:
        source_id = entry["source"]["id"]
        initial_body = render_body(manifest, entry, {}, final=False)
        target = entry["target"]
        requests.append(
            {
                "operation": "refresh-marker-before-create",
                "source_id": source_id,
                "method": "GET-paginated-if-marker-missing",
                "path": "repos/%s/issues?state=all" % repository,
            }
        )
        requests.append(
            {
                "operation": "create-or-recover",
                "source_id": source_id,
                "method": "POST-if-marker-missing",
                "path": "repos/%s/issues" % repository,
                "payload": {
                    "title": target["title"],
                    "body": initial_body,
                    "labels": target["labels"],
                    "assignees": target.get("assignees", []),
                },
            }
        )
        requests.append(
            {
                "operation": "read-back-create",
                "source_id": source_id,
                "method": "GET-if-created",
                "path": "repos/%s/issues/{target-number}" % repository,
            }
        )
        if target["state"] == "closed":
            requests.append(
                {
                    "operation": "refresh-before-terminal-state",
                    "source_id": source_id,
                    "method": "GET-if-open",
                    "path": "repos/%s/issues/{target-number}" % repository,
                }
            )
            requests.append(
                {
                    "operation": "set-terminal-state",
                    "source_id": source_id,
                    "method": "PATCH-if-open",
                    "path": "repos/%s/issues/{target-number}" % repository,
                    "payload": {"state": "closed", "state_reason": target["state_reason"]},
                }
            )
            requests.append(
                {
                    "operation": "read-back-terminal-state",
                    "source_id": source_id,
                    "method": "GET-if-patched",
                    "path": "repos/%s/issues/{target-number}" % repository,
                }
            )
        requests.append(
            {
                "operation": "refresh-before-link-repair",
                "source_id": source_id,
                "method": "GET",
                "path": "repos/%s/issues/{target-number}" % repository,
            }
        )
        if any(kind == "target" for kind, _ in PLACEHOLDER.findall(target["body_template"])):
            requests.append(
                {
                    "operation": "repair-links",
                    "source_id": source_id,
                    "method": "PATCH-after-all-targets-exist",
                    "path": "repos/%s/issues/{target-number}" % repository,
                    "payload": {"body_template": target["body_template"]},
                }
            )
            requests.append(
                {
                    "operation": "read-back-link-repair",
                    "source_id": source_id,
                    "method": "GET-if-patched",
                    "path": "repos/%s/issues/{target-number}" % repository,
                }
            )
    requests.extend(
        [
            {"operation": "final-target-export", "method": "GET-paginated", "path": "repos/%s/issues?state=all" % repository},
            {"operation": "final-label-verification", "method": "GET-paginated", "path": "repos/%s/labels" % repository},
        ]
    )
    output = {
        "dry_run": True,
        "network_mutations": 0,
        "manifest_sha256": digest,
        "repository": repository,
        "target_transformations": manifest["entries"],
        "planned_requests": requests,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


def parse_arguments(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subcommands = parser.add_subparsers(dest="command", required=True)

    build = subcommands.add_parser("build-pilot-manifest")
    build.add_argument("--source-repository", default="Seigiard/my-mac-setup")
    build.add_argument("--source-commit", required=True)
    build.add_argument("--target-repository", required=True)
    build.add_argument("--output", type=Path, required=True)

    plan = subcommands.add_parser("dry-run")
    plan.add_argument("--manifest", type=Path, required=True)
    plan.add_argument("--repo", required=True)

    apply = subcommands.add_parser("apply")
    apply.add_argument("--manifest", type=Path, required=True)
    apply.add_argument("--state", type=Path, required=True)
    apply.add_argument("--repo", required=True)
    apply.add_argument("--interrupt-after-create", type=int)
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = parse_arguments(argv)
    try:
        if arguments.command == "build-pilot-manifest":
            manifest = build_pilot_manifest(arguments.source_repository, arguments.source_commit, arguments.target_repository)
            atomic_write_json(arguments.output, manifest)
            print(arguments.output)
            return 0
        if arguments.command == "dry-run":
            return dry_run(arguments.manifest, arguments.repo)
        if arguments.command == "apply":
            if arguments.interrupt_after_create is not None and arguments.interrupt_after_create < 1:
                raise MigrationError("--interrupt-after-create must be positive")
            with migration_lock(arguments.state, arguments.repo):
                return apply_manifest(arguments.manifest, arguments.state, arguments.repo, arguments.interrupt_after_create)
        raise MigrationError("unsupported command")
    except MigrationError as error:
        print("MIGRATION_FAILED: %s" % error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
