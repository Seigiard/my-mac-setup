#!/usr/bin/env python3

import argparse
import json
import os
import signal
import subprocess
import sys


class SnapshotError(ValueError):
    pass


class SnapshotTimeout(TimeoutError):
    pass


def required_string(value, path):
    if not isinstance(value, str) or not value:
        raise SnapshotError(f"{path} must be a non-empty string")
    return value


def optional_label(value, path):
    if value is not None and not isinstance(value, str):
        raise SnapshotError(f"{path} must be a string or null")
    return value


def required_number(value, path):
    if isinstance(value, bool) or not isinstance(value, int):
        raise SnapshotError(f"{path} must be an integer")
    return value


def required_list(value, path):
    if not isinstance(value, list):
        raise SnapshotError(f"{path} must be an array")
    return value


def resource_index(records, kind, id_key):
    indexed = {}
    for index, record in enumerate(records):
        path = f"snapshot.{kind}[{index}]"
        if not isinstance(record, dict):
            raise SnapshotError(f"{path} must be an object")
        resource_id = required_string(record.get(id_key), f"{path}.{id_key}")
        if resource_id in indexed:
            raise SnapshotError(f"duplicate {id_key} {resource_id!r}")
        indexed[resource_id] = (record, path)
    return indexed


def normalize_session(value, path):
    if value is None:
        return None
    if not isinstance(value, dict):
        raise SnapshotError(f"{path} must be an object or null")
    return {
        key: required_string(value.get(key), f"{path}.{key}")
        for key in ("agent", "kind", "source", "value")
    }


def normalize_snapshot(envelope):
    if not isinstance(envelope, dict):
        raise SnapshotError("response must be a JSON object")
    result = envelope.get("result")
    if not isinstance(result, dict) or result.get("type") != "session_snapshot":
        raise SnapshotError("result must be a session_snapshot object")
    snapshot = result.get("snapshot")
    if not isinstance(snapshot, dict):
        raise SnapshotError("result.snapshot must be an object")

    workspaces = required_list(snapshot.get("workspaces"), "snapshot.workspaces")
    tabs = required_list(snapshot.get("tabs"), "snapshot.tabs")
    panes = required_list(snapshot.get("panes"), "snapshot.panes")
    agents = required_list(snapshot.get("agents"), "snapshot.agents")
    workspace_index = resource_index(workspaces, "workspaces", "workspace_id")
    tab_index = resource_index(tabs, "tabs", "tab_id")
    pane_index = resource_index(panes, "panes", "pane_id")

    observed_agents = {}
    for index, agent in enumerate(agents):
        path = f"snapshot.agents[{index}]"
        if not isinstance(agent, dict):
            raise SnapshotError(f"{path} must be an object")
        pane_id = required_string(agent.get("pane_id"), f"{path}.pane_id")
        if pane_id not in pane_index:
            raise SnapshotError(f"{path}.pane_id references unknown pane {pane_id!r}")
        if pane_id in observed_agents:
            raise SnapshotError(f"multiple agent observations reference pane {pane_id!r}")

        pane, _ = pane_index[pane_id]
        for key in ("workspace_id", "tab_id", "terminal_id"):
            observed = required_string(agent.get(key), f"{path}.{key}")
            if observed != pane.get(key):
                raise SnapshotError(
                    f"{path}.{key} does not match pane {pane_id!r}"
                )
        observed_agents[pane_id] = {
            "client": required_string(agent.get("agent"), f"{path}.agent"),
            "presentation_name": required_string(agent.get("name"), f"{path}.name"),
            "session": normalize_session(agent.get("agent_session"), f"{path}.agent_session"),
            "parent_session": None,
        }

    normalized_workspaces = []
    for workspace_id, (workspace, path) in workspace_index.items():
        workspace_number = required_number(workspace.get("number"), f"{path}.number")
        normalized_tabs = []
        for tab_id, (tab, tab_path) in tab_index.items():
            if tab.get("workspace_id") != workspace_id:
                continue
            tab_number = required_number(tab.get("number"), f"{tab_path}.number")
            normalized_panes = []
            for pane_id, (pane, pane_path) in pane_index.items():
                if pane.get("tab_id") != tab_id:
                    continue
                if pane.get("workspace_id") != workspace_id:
                    raise SnapshotError(
                        f"{pane_path}.workspace_id does not match tab {tab_id!r}"
                    )
                normalized_panes.append(
                    {
                        "id": pane_id,
                        "label": optional_label(pane.get("label"), f"{pane_path}.label"),
                        "terminal_id": required_string(
                            pane.get("terminal_id"), f"{pane_path}.terminal_id"
                        ),
                        "creator_session": None,
                        "agent": observed_agents.get(pane_id),
                    }
                )
            normalized_panes.sort(key=lambda pane: pane["id"])
            normalized_tabs.append(
                {
                    "id": tab_id,
                    "number": tab_number,
                    "label": optional_label(tab.get("label"), f"{tab_path}.label"),
                    "creator_session": None,
                    "panes": normalized_panes,
                }
            )
        normalized_tabs.sort(key=lambda tab: (tab["number"], tab["id"]))
        normalized_workspaces.append(
            {
                "id": workspace_id,
                "number": workspace_number,
                "label": optional_label(workspace.get("label"), f"{path}.label"),
                "creator_session": None,
                "tabs": normalized_tabs,
            }
        )

    for tab_id, (tab, path) in tab_index.items():
        workspace_id = required_string(tab.get("workspace_id"), f"{path}.workspace_id")
        if workspace_id not in workspace_index:
            raise SnapshotError(
                f"{path}.workspace_id references unknown workspace {workspace_id!r}"
            )
    for pane_id, (pane, path) in pane_index.items():
        tab_id = required_string(pane.get("tab_id"), f"{path}.tab_id")
        workspace_id = required_string(pane.get("workspace_id"), f"{path}.workspace_id")
        if tab_id not in tab_index:
            raise SnapshotError(f"{path}.tab_id references unknown tab {tab_id!r}")
        if workspace_id not in workspace_index:
            raise SnapshotError(
                f"{path}.workspace_id references unknown workspace {workspace_id!r}"
            )

    normalized_workspaces.sort(
        key=lambda workspace: (workspace["number"], workspace["id"])
    )
    return {
        "schema_version": 1,
        "scope": {
            "kind": "local-herdr-server",
            "version": required_string(snapshot.get("version"), "snapshot.version"),
            "protocol": required_number(snapshot.get("protocol"), "snapshot.protocol"),
        },
        "workspaces": normalized_workspaces,
    }


def display_label(label):
    if label is None:
        return "(unlabeled)"
    return json.dumps(label, ensure_ascii=False)


def display_session(session):
    if session is None:
        return "unknown"
    return "/".join(
        (session["source"], session["kind"], session["value"])
    )


def render_human(tree):
    scope = tree["scope"]
    lines = [
        f"local Herdr server (version {scope['version']}, protocol {scope['protocol']})"
    ]
    if not tree["workspaces"]:
        lines.append("(no open workspaces)")
        return "\n".join(lines)

    for workspace in tree["workspaces"]:
        lines.append(f"workspace {display_label(workspace['label'])} [{workspace['id']}]")
        lines.append("  creator: unknown")
        for tab in workspace["tabs"]:
            lines.append(f"  tab {display_label(tab['label'])} [{tab['id']}]")
            lines.append("    creator: unknown")
            for pane in tab["panes"]:
                lines.append(f"    pane {display_label(pane['label'])} [{pane['id']}]")
                lines.append(f"      terminal: {pane['terminal_id']}")
                lines.append("      creator: unknown")
                agent = pane["agent"]
                if agent is None:
                    lines.append("      agent: none")
                    continue
                lines.append(
                    f"      agent: {agent['client']} "
                    f"{display_label(agent['presentation_name'])}"
                )
                lines.append(f"      session: {display_session(agent['session'])}")
                lines.append("      parent: unknown")
    return "\n".join(lines)


def retrieve_snapshot():
    process = subprocess.Popen(
        ["herdr", "api", "snapshot"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=10)
    except subprocess.TimeoutExpired as error:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=1)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
        raise SnapshotTimeout("herdr api snapshot timed out after 10 seconds") from error
    return subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="herdr-resource-tree",
        description="Show the open resources on one local Herdr server.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="emit the versioned machine-readable resource tree",
    )
    return parser.parse_args(argv)


def main(argv):
    args = parse_args(argv)
    try:
        completed = retrieve_snapshot()
    except SnapshotTimeout as error:
        print(f"herdr-resource-tree: snapshot retrieval failed: {error}", file=sys.stderr)
        return 124
    except OSError as error:
        print(f"herdr-resource-tree: snapshot retrieval failed: {error}", file=sys.stderr)
        return 1

    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        if not detail:
            detail = f"herdr exited with status {completed.returncode}"
        print(
            f"herdr-resource-tree: snapshot retrieval failed: {detail}",
            file=sys.stderr,
        )
        if 1 <= completed.returncode <= 125:
            return completed.returncode
        return 1

    try:
        envelope = json.loads(completed.stdout)
        tree = normalize_snapshot(envelope)
    except (json.JSONDecodeError, SnapshotError) as error:
        print(f"herdr-resource-tree: malformed snapshot: {error}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(tree, ensure_ascii=False, indent=2))
    else:
        print(render_human(tree))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
