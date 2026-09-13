#!/usr/bin/env python3
"""High-level verifier for the temporary GitHub issue migration."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Any, Dict, List, Mapping, Optional, Sequence


MARKER_PREFIX = "<!-- my-mac-setup-issue-migration:"
MARKER_SUFFIX = " -->"


class VerificationError(RuntimeError):
    pass


def gh_api(endpoint: str) -> Any:
    result = subprocess.run(["gh", "api", endpoint], text=True, capture_output=True, check=False)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "gh api failed"
        raise VerificationError("%s: %s" % (endpoint, detail))
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise VerificationError("%s returned invalid JSON" % endpoint) from error


def paginated(endpoint: str) -> List[Dict[str, Any]]:
    separator = "&" if "?" in endpoint else "?"
    output: List[Dict[str, Any]] = []
    page = 1
    while True:
        values = gh_api("%s%sper_page=100&page=%d" % (endpoint, separator, page))
        if not isinstance(values, list):
            raise VerificationError("expected list from %s" % endpoint)
        output.extend(values)
        if len(values) < 100:
            return output
        page += 1


def load_json(path: Path, label: str) -> Dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise VerificationError("cannot read %s: %s" % (label, error)) from error
    if not isinstance(value, dict):
        raise VerificationError("%s must be a JSON object" % label)
    return value


def verify_empty(repository: str) -> Dict[str, Any]:
    metadata = gh_api("repos/%s" % repository)
    issues = [issue for issue in paginated("repos/%s/issues?state=all&" % repository) if "pull_request" not in issue]
    if not metadata.get("private"):
        raise VerificationError("scratch repository is not private")
    if not metadata.get("has_issues"):
        raise VerificationError("scratch repository does not have Issues enabled")
    if issues:
        raise VerificationError("scratch repository is not empty: %d issues" % len(issues))
    return {
        "repository": repository,
        "private": True,
        "has_issues": True,
        "issue_count": 0,
        "default_branch": metadata.get("default_branch"),
        "html_url": metadata["html_url"],
    }


def expected_body(manifest: Mapping[str, Any], entry: Mapping[str, Any], state: Mapping[str, Any]) -> str:
    body = entry["target"]["body_template"]
    source_paths = {entry["source"]["path"]}
    if entry["source"].get("parent_plan"):
        source_paths.add(entry["source"]["parent_plan"])
    source_paths.update(
        relation["value"]
        for relation in entry.get("relations", [])
        if relation["kind"] == "source"
    )
    for path in source_paths:
        source_url = "https://github.com/%s/blob/%s/%s" % (
            manifest["source_repository"],
            manifest["source_commit"],
            path,
        )
        body = body.replace("{{source:%s}}" % path, source_url)
    for relation in entry.get("relations", []):
        if relation["kind"] != "target":
            continue
        try:
            target_url = state["issues"][relation["value"]]["url"]
        except KeyError as error:
            raise VerificationError("missing target mapping for %s" % relation["value"]) from error
        body = body.replace("{{target:%s}}" % relation["value"], target_url)
    if "{{source:" in body or "{{target:" in body:
        raise VerificationError("manifest body retains an unresolved placeholder")
    return body


def body_markers(body: str) -> List[str]:
    markers = []
    for line in body.splitlines():
        if line.startswith(MARKER_PREFIX) and line.endswith(MARKER_SUFFIX):
            markers.append(line[len(MARKER_PREFIX) : -len(MARKER_SUFFIX)])
    return markers


def target_entries(manifest: Mapping[str, Any]) -> List[Mapping[str, Any]]:
    return [entry for entry in manifest["entries"] if entry.get("target")]


def stable_export(issue: Mapping[str, Any], source_id: str) -> Dict[str, Any]:
    return {
        "source_id": source_id,
        "number": issue["number"],
        "url": issue["html_url"],
        "node_id": issue["node_id"],
        "title": issue["title"],
        "body": issue.get("body") or "",
        "labels": sorted(label["name"] for label in issue.get("labels", [])),
        "assignees": sorted(assignee["login"] for assignee in issue.get("assignees", [])),
        "state": issue["state"],
        "state_reason": issue.get("state_reason"),
    }


def require_equal(source_id: str, field: str, observed: Any, expected: Any, number: int) -> None:
    if observed == expected:
        return
    if field == "body":
        observed = hashlib.sha256(observed.encode("utf-8")).hexdigest()
        expected = hashlib.sha256(expected.encode("utf-8")).hexdigest()
    raise VerificationError(
        "source=%s target=#%d field=%s observed=%r expected=%r"
        % (source_id, number, field, observed, expected)
    )


def verify_migration(manifest_path: Path, state_path: Path, repository: str, require_no_unmarked: bool) -> Dict[str, Any]:
    manifest = load_json(manifest_path, "manifest")
    state = load_json(state_path, "state")
    if manifest.get("target_repository") != repository:
        raise VerificationError("manifest targets a different repository")
    metadata = gh_api("repos/%s" % repository)
    policy = manifest.get("target_policy", {})
    if metadata.get("full_name", "").casefold() != repository.casefold():
        raise VerificationError("GitHub resolved an unexpected target repository")
    if bool(metadata.get("private")) != bool(policy.get("private")):
        raise VerificationError("target repository privacy differs from the manifest")
    if not metadata.get("has_issues") or metadata.get("archived"):
        raise VerificationError("target repository is not an active Issues repository")
    if not state.get("complete"):
        raise VerificationError("importer state is not complete")
    if state.get("target_repository") != repository:
        raise VerificationError("state targets a different repository")
    manifest_digest = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    if state.get("manifest_sha256") != manifest_digest:
        raise VerificationError("state manifest digest differs from the reviewed manifest")

    entries = {entry["source"]["id"]: entry for entry in target_entries(manifest)}
    issues = [issue for issue in paginated("repos/%s/issues?state=all&" % repository) if "pull_request" not in issue]
    labels = {label["name"]: label for label in paginated("repos/%s/labels?" % repository)}
    for expected in manifest["labels"]:
        observed = labels.get(expected["name"])
        if not observed:
            raise VerificationError("missing label definition %s" % expected["name"])
        if observed["color"].lower() != expected["color"].lower() or (observed.get("description") or "") != expected["description"]:
            raise VerificationError("label definition drift for %s" % expected["name"])
    by_marker: Dict[str, List[Mapping[str, Any]]] = {}
    unmarked = []
    for issue in issues:
        markers = body_markers(issue.get("body") or "")
        if not markers:
            unmarked.append(issue["number"])
            continue
        if len(markers) != 1:
            raise VerificationError("target #%d has %d migration markers" % (issue["number"], len(markers)))
        by_marker.setdefault(markers[0], []).append(issue)
    if (require_no_unmarked or policy.get("require_empty_on_first_apply")) and unmarked:
        raise VerificationError("unexpected unmarked issues: %s" % unmarked)
    unknown = sorted(set(by_marker) - set(entries))
    if unknown:
        raise VerificationError("unknown migration markers: %s" % unknown)

    exported = []
    repaired_links = 0
    for source_id, entry in entries.items():
        matched = by_marker.get(source_id, [])
        if len(matched) != 1:
            raise VerificationError("source=%s target_count=%d" % (source_id, len(matched)))
        issue = matched[0]
        mapping = state.get("issues", {}).get(source_id)
        if not mapping or mapping.get("number") != issue["number"] or mapping.get("url") != issue["html_url"] or mapping.get("node_id") != issue["node_id"]:
            raise VerificationError("source=%s state identity does not match GitHub" % source_id)
        target = entry["target"]
        body = issue.get("body") or ""
        wanted_body = expected_body(manifest, entry, state)
        require_equal(source_id, "title", issue["title"], target["title"], issue["number"])
        require_equal(source_id, "body", body, wanted_body, issue["number"])
        require_equal(source_id, "labels", sorted(label["name"] for label in issue["labels"]), sorted(target["labels"]), issue["number"])
        require_equal(source_id, "assignees", sorted(value["login"] for value in issue["assignees"]), sorted(target.get("assignees", [])), issue["number"])
        require_equal(source_id, "state", issue["state"], target["state"], issue["number"])
        require_equal(source_id, "state_reason", issue.get("state_reason"), target.get("state_reason"), issue["number"])
        if body.count("<!-- my-mac-setup-issue-migration:%s -->" % source_id) != 1:
            raise VerificationError("source=%s marker count is not one" % source_id)
        if "{{source:" in body or "{{target:" in body:
            raise VerificationError("source=%s retains an unresolved placeholder" % source_id)
        for relation in entry.get("relations", []):
            kind = relation["kind"]
            value = relation["value"]
            expected_link = (
                state["issues"][value]["url"]
                if kind == "target"
                else "https://github.com/%s/blob/%s/%s" % (manifest["source_repository"], manifest["source_commit"], value)
            )
            legacy_id = value if kind == "target" else Path(value).name[:14]
            expected_markdown = "[legacy issue `%s`](%s)" % (legacy_id, expected_link)
            boundary = re.compile(
                r"(?<![A-Za-z0-9_/-])%s(?![A-Za-z0-9_/-])" % re.escape(expected_markdown)
            )
            occurrences = relation.get("occurrences", 1)
            if len(boundary.findall(body)) != occurrences:
                raise VerificationError("source=%s missing repaired Markdown link %s" % (source_id, expected_markdown))
            repaired_links += occurrences
        exported.append(stable_export(issue, source_id))

    return {
        "schema_version": 1,
        "repository": repository,
        "manifest_sha256": manifest_digest,
        "verified": True,
        "issue_count": len(exported),
        "unmarked_issue_count": len(unmarked),
        "duplicate_issue_count": sum(max(0, count - 1) for count in (len(values) for values in by_marker.values())),
        "duplicate_marker_count": sum(max(0, count - 1) for count in (len(values) for values in by_marker.values())),
        "repaired_link_count": repaired_links,
        "issues": sorted(exported, key=lambda value: value["number"]),
    }


def replay_export(manifest_path: Path, state_path: Path, export_path: Path) -> Dict[str, Any]:
    manifest = load_json(manifest_path, "manifest")
    state = load_json(state_path, "state")
    exported = load_json(export_path, "target export")
    repository = manifest.get("target_repository")
    digest = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    if not state.get("complete") or state.get("target_repository") != repository or state.get("manifest_sha256") != digest:
        raise VerificationError("importer state identity differs from the manifest")
    if exported.get("repository") != repository or exported.get("manifest_sha256") != digest:
        raise VerificationError("target export identity differs from the manifest")
    records = exported.get("issues")
    if not isinstance(records, list):
        raise VerificationError("target export issues must be a list")
    by_source = {record.get("source_id"): record for record in records}
    if len(by_source) != len(records):
        raise VerificationError("target export contains duplicate source IDs")
    if set(by_source) != {entry["source"]["id"] for entry in target_entries(manifest)}:
        raise VerificationError("target export source set differs from the manifest")

    repaired_links = 0
    for entry in target_entries(manifest):
        source_id = entry["source"]["id"]
        record = by_source[source_id]
        target = entry["target"]
        number = record["number"]
        require_equal(source_id, "title", record["title"], target["title"], number)
        require_equal(source_id, "body", record["body"], expected_body(manifest, entry, state), number)
        require_equal(source_id, "labels", sorted(record["labels"]), sorted(target["labels"]), number)
        require_equal(source_id, "assignees", sorted(record["assignees"]), sorted(target.get("assignees", [])), number)
        require_equal(source_id, "state", record["state"], target["state"], number)
        require_equal(source_id, "state_reason", record.get("state_reason"), target.get("state_reason"), number)
        if body_markers(record["body"]) != [source_id]:
            raise VerificationError("source=%s marker mismatch in retained export" % source_id)
        for relation in entry.get("relations", []):
            link = (
                state["issues"][relation["value"]]["url"]
                if relation["kind"] == "target"
                else "https://github.com/%s/blob/%s/%s"
                % (manifest["source_repository"], manifest["source_commit"], relation["value"])
            )
            legacy_id = relation["value"] if relation["kind"] == "target" else Path(relation["value"]).name[:14]
            markdown = "[legacy issue `%s`](%s)" % (legacy_id, link)
            if record["body"].count(markdown) != relation.get("occurrences", 1):
                raise VerificationError("source=%s repaired link mismatch in retained export" % source_id)
            repaired_links += relation.get("occurrences", 1)
    return {
        "schema_version": 1,
        "repository": repository,
        "manifest_sha256": digest,
        "command_status": 0,
        "replayed": True,
        "issue_count": len(records),
        "repaired_link_count": repaired_links,
    }


def parse_arguments(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subcommands = parser.add_subparsers(dest="command", required=True)
    empty = subcommands.add_parser("empty")
    empty.add_argument("--repo", required=True)
    empty.add_argument("--output", type=Path)
    verify = subcommands.add_parser("verify")
    verify.add_argument("--manifest", type=Path, required=True)
    verify.add_argument("--state", type=Path, required=True)
    verify.add_argument("--repo", required=True)
    verify.add_argument("--require-no-unmarked", action="store_true")
    verify.add_argument("--output", type=Path)
    replay = subcommands.add_parser("replay")
    replay.add_argument("--manifest", type=Path, required=True)
    replay.add_argument("--state", type=Path, required=True)
    replay.add_argument("--export", type=Path, required=True)
    return parser.parse_args(argv)


def write_result(value: Mapping[str, Any], output: Optional[Path]) -> None:
    if output:
        rendered = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered, encoding="utf-8")
    print(json.dumps({key: value[key] for key in value if key not in ("issues",)}, sort_keys=True))


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = parse_arguments(argv)
    try:
        if arguments.command == "empty":
            value = verify_empty(arguments.repo)
        elif arguments.command == "verify":
            value = verify_migration(arguments.manifest, arguments.state, arguments.repo, arguments.require_no_unmarked)
        else:
            value = replay_export(arguments.manifest, arguments.state, arguments.export)
        write_result(value, getattr(arguments, "output", None))
        return 0
    except VerificationError as error:
        print("VERIFICATION_FAILED status=1: %s" % error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
