#!/usr/bin/env python3

import argparse
import json
import os
import signal
import sqlite3
import subprocess
import sys
import uuid


class SnapshotError(ValueError):
    pass


class SnapshotTimeout(TimeoutError):
    pass


class RegistryError(RuntimeError):
    pass


class CapturedCommandTimeout(TimeoutError):
    def __init__(self, stdout, stderr):
        super().__init__("captured command timed out")
        self.stdout = stdout
        self.stderr = stderr


class CreatedPaneError(SnapshotError):
    def __init__(self, message, coordinates):
        super().__init__(message)
        self.coordinates = coordinates


def run_captured(argv, timeout):
    process = subprocess.Popen(
        argv,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            stdout, stderr = process.communicate(timeout=1)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            stdout, stderr = process.communicate()
        raise CapturedCommandTimeout(stdout, stderr)
    return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)


def same_executable(left, right):
    try:
        return os.path.samefile(left, right)
    except (FileNotFoundError, OSError):
        return os.path.realpath(left) == os.path.realpath(right)


def find_original_herdr(wrapper_path):
    candidates = []
    configured = os.environ.get("HERDR_BIN_PATH")
    if configured:
        candidates.append(configured)
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidates.append(os.path.join(directory or os.curdir, "herdr"))

    for candidate in candidates:
        if not os.path.isfile(candidate) or not os.access(candidate, os.X_OK):
            continue
        if same_executable(candidate, wrapper_path):
            continue
        return os.path.abspath(candidate)
    raise FileNotFoundError("original herdr executable not found outside the wrapper")


def state_database_path():
    state_home = os.environ.get("HERDR_RESOURCE_TREE_STATE_DIR")
    if not state_home:
        state_home = os.path.join(
            os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
            "herdr-resource-tree",
        )
    return os.path.join(state_home, "registry.sqlite3")


def server_scope():
    socket_path = (
        os.environ.get("HERDR_CLIENT_SOCKET_PATH")
        or os.environ.get("HERDR_SOCKET_PATH")
        or os.path.join(
            os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
            "herdr",
            "herdr.sock",
        )
    )
    socket_path = os.path.realpath(os.path.expanduser(socket_path))
    try:
        socket_identity = os.stat(socket_path)
    except OSError as error:
        raise RegistryError(
            f"local Herdr socket identity unavailable for {socket_path}: {error}"
        ) from error
    return f"socket:{socket_path}:{socket_identity.st_dev}:{socket_identity.st_ino}"


def connect_registry(create):
    database = state_database_path()
    if not create and not os.path.exists(database):
        return None
    try:
        if create:
            directory = os.path.dirname(database)
            os.makedirs(directory, mode=0o700, exist_ok=True)
            os.chmod(directory, 0o700)
        connection = sqlite3.connect(database, timeout=5)
        connection.execute("PRAGMA busy_timeout = 5000")
        connection.execute("PRAGMA synchronous = FULL")
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS operations (
                operation_id TEXT PRIMARY KEY,
                server_scope TEXT NOT NULL,
                caller_session TEXT NOT NULL,
                caller_pane_id TEXT NOT NULL,
                caller_terminal_id TEXT NOT NULL,
                status TEXT NOT NULL,
                native_exit_status INTEGER,
                pane_id TEXT,
                terminal_id TEXT,
                workspace_id TEXT,
                tab_id TEXT
            )
            """
        )
        connection.execute(
            """
            CREATE INDEX IF NOT EXISTS operations_creator_lookup
            ON operations (server_scope, status, pane_id, terminal_id)
            """
        )
        connection.commit()
        if create:
            os.chmod(database, 0o600)
        return connection
    except (OSError, sqlite3.Error) as error:
        raise RegistryError(str(error)) from error


def record_intent(operation_id, scope, caller):
    connection = connect_registry(create=True)
    try:
        with connection:
            connection.execute(
                """
                INSERT INTO operations (
                    operation_id, server_scope, caller_session,
                    caller_pane_id, caller_terminal_id, status
                ) VALUES (?, ?, ?, ?, ?, 'intent-recorded')
                """,
                (
                    operation_id,
                    scope,
                    json.dumps(caller["session"], sort_keys=True),
                    caller["pane_id"],
                    caller["terminal_id"],
                ),
            )
    except sqlite3.Error as error:
        raise RegistryError(str(error)) from error
    finally:
        connection.close()


def record_native_failure(operation_id, exit_status):
    try:
        connection = connect_registry(create=True)
        with connection:
            connection.execute(
                "UPDATE operations SET status = 'native-failed', "
                "native_exit_status = ? WHERE operation_id = ?",
                (exit_status, operation_id),
            )
        connection.close()
    except RegistryError:
        pass
    except sqlite3.Error:
        connection.close()


def finalize_operation(operation_id, pane):
    if os.environ.get("HERDR_RESOURCE_TREE_TEST_FAIL_FINALIZE") == "1":
        raise RegistryError("injected finalization failure")
    connection = connect_registry(create=True)
    try:
        with connection:
            cursor = connection.execute(
                """
                UPDATE operations
                SET status = 'finalized', pane_id = ?, terminal_id = ?,
                    workspace_id = ?, tab_id = ?
                WHERE operation_id = ? AND status = 'intent-recorded'
                """,
                (
                    pane["pane_id"],
                    pane["terminal_id"],
                    pane["workspace_id"],
                    pane["tab_id"],
                    operation_id,
                ),
            )
            if cursor.rowcount != 1:
                raise RegistryError("operation intent is no longer finalizable")
    except sqlite3.Error as error:
        raise RegistryError(str(error)) from error
    finally:
        connection.close()


def parse_current_caller(stdout):
    try:
        envelope = json.loads(stdout)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SnapshotError(f"current pane response is not valid JSON: {error}") from error
    result = envelope.get("result") if isinstance(envelope, dict) else None
    pane = result.get("pane") if isinstance(result, dict) else None
    if not isinstance(pane, dict):
        raise SnapshotError("current pane response has no result.pane object")
    if not pane.get("agent"):
        return None
    session = normalize_session(pane.get("agent_session"), "current pane agent_session")
    if session is None:
        raise SnapshotError("current pane agent_session is required for an observed agent")
    return {
        "session": session,
        "pane_id": required_string(pane.get("pane_id"), "current pane pane_id"),
        "terminal_id": required_string(
            pane.get("terminal_id"), "current pane terminal_id"
        ),
    }


def identify_caller(original):
    try:
        completed = run_captured(
            [original, "pane", "current", "--current"], timeout=10
        )
    except CapturedCommandTimeout as error:
        raise SnapshotError("current pane lookup timed out after 10 seconds") from error
    if completed.returncode != 0:
        if os.environ.get("HERDR_PANE_ID"):
            detail = completed.stderr.decode(errors="replace").strip()
            raise SnapshotError(detail or "current pane lookup failed")
        return None
    return parse_current_caller(completed.stdout)


def parse_created_pane(stdout):
    try:
        envelope = json.loads(stdout)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SnapshotError(f"native success response is not valid JSON: {error}") from error
    result = envelope.get("result") if isinstance(envelope, dict) else None
    pane = result.get("pane") if isinstance(result, dict) else None
    if not isinstance(pane, dict):
        raise SnapshotError("native success response has no result.pane object")
    coordinates = {}
    first_error = None
    for key in ("pane_id", "terminal_id", "workspace_id", "tab_id"):
        try:
            coordinates[key] = required_string(pane.get(key), f"created pane {key}")
        except SnapshotError as error:
            if first_error is None:
                first_error = error
    if first_error is not None:
        raise CreatedPaneError(str(first_error), coordinates) from first_error
    return coordinates


def write_native_output(completed):
    sys.stdout.buffer.write(completed.stdout)
    sys.stdout.buffer.flush()
    sys.stderr.buffer.write(completed.stderr)
    sys.stderr.buffer.flush()


def report_untracked_creation(operation_id, pane, detail):
    coordinates = ""
    if pane:
        coordinates = " " + " ".join(f"{key}={value}" for key, value in pane.items())
    print(
        f"herdr wrapper: creation operation {operation_id}{coordinates} succeeded, "
        f"but provenance finalization failed: {detail}; the resource remains open "
        "and automatic creation retry is unsafe; do not retry creation",
        file=sys.stderr,
    )


def report_uncertain_creation(operation_id, detail):
    print(
        f"herdr wrapper: creation operation {operation_id} may have created a resource, "
        f"but no recoverable response is available: {detail}; automatic creation retry "
        "is unsafe; do not retry creation",
        file=sys.stderr,
    )


def managed_split(original, argv, caller):
    operation_id = str(uuid.uuid4())
    try:
        scope = server_scope()
        record_intent(operation_id, scope, caller)
    except RegistryError as error:
        print(
            f"herdr wrapper: intent recording failed; native creation was not called: {error}",
            file=sys.stderr,
        )
        return 69

    native_argv = [
        original,
        *argv,
        "--env",
        f"HERDR_RESOURCE_OPERATION_ID={operation_id}",
    ]
    try:
        completed = run_captured(native_argv, timeout=30)
    except OSError as error:
        record_native_failure(operation_id, 127)
        print(f"herdr wrapper: native creation was not started: {error}", file=sys.stderr)
        return 127
    except CapturedCommandTimeout as error:
        completed = subprocess.CompletedProcess(
            native_argv, 124, error.stdout, error.stderr
        )
        write_native_output(completed)
        report_uncertain_creation(operation_id, "native creation timed out after 30 seconds")
        return 124
    write_native_output(completed)
    if completed.returncode != 0:
        record_native_failure(operation_id, completed.returncode)
        if completed.returncode < 0:
            return 128 - completed.returncode
        return completed.returncode

    pane = None
    try:
        pane = parse_created_pane(completed.stdout)
        finalize_operation(operation_id, pane)
    except CreatedPaneError as error:
        pane = error.coordinates
        report_untracked_creation(operation_id, pane, error)
        return 70
    except (SnapshotError, RegistryError) as error:
        report_untracked_creation(operation_id, pane, error)
        return 70
    return 0


def wrapper_main(wrapper_path, argv):
    try:
        original = find_original_herdr(wrapper_path)
    except OSError as error:
        print(f"herdr wrapper: {error}", file=sys.stderr)
        return 127
    if argv[:2] == ["pane", "split"] and not any(
        argument in ("-h", "--help") for argument in argv[2:]
    ):
        try:
            caller = identify_caller(original)
        except (OSError, SnapshotError) as error:
            print(
                "herdr wrapper: caller identity unavailable; native creation was not "
                f"called: {error}",
                file=sys.stderr,
            )
            return 69
        if caller is not None:
            return managed_split(original, argv, caller)
    os.execv(original, [original, *argv])


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


def load_creator_edges(scope):
    connection = connect_registry(create=False)
    if connection is None:
        return {}
    try:
        rows = connection.execute(
            """
            SELECT pane_id, terminal_id, caller_session
            FROM operations
            WHERE server_scope = ? AND status = 'finalized'
            """,
            (scope,),
        ).fetchall()
    except sqlite3.Error as error:
        raise RegistryError(str(error)) from error
    finally:
        connection.close()

    edges = {}
    for pane_id, terminal_id, encoded_session in rows:
        try:
            session = normalize_session(
                json.loads(encoded_session),
                f"stored creator for pane {pane_id!r}",
            )
        except (json.JSONDecodeError, SnapshotError) as error:
            raise RegistryError(str(error)) from error
        key = (pane_id, terminal_id)
        if key in edges and edges[key] != session:
            raise RegistryError(
                f"conflicting creator records for pane {pane_id!r} terminal {terminal_id!r}"
            )
        edges[key] = session
    return edges


def apply_creator_edges(tree, edges):
    for workspace in tree["workspaces"]:
        for tab in workspace["tabs"]:
            for pane in tab["panes"]:
                pane["creator_session"] = edges.get(
                    (pane["id"], pane["terminal_id"])
                )


def filter_creator_branch(tree, session):
    workspaces = []
    for workspace in tree["workspaces"]:
        tabs = []
        for tab in workspace["tabs"]:
            panes = [
                pane for pane in tab["panes"] if pane["creator_session"] == session
            ]
            if panes:
                tabs.append({**tab, "panes": panes})
        if tabs:
            workspaces.append({**workspace, "tabs": tabs})
    return {**tree, "workspaces": workspaces}


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
                lines.append(
                    f"      creator: {display_session(pane['creator_session'])}"
                )
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
    parser.add_argument(
        "--branch",
        action="store_true",
        help="show only panes created by the invoking agent session",
    )
    return parser.parse_args(argv)


def main(argv):
    if argv and argv[0] == "--wrap":
        if len(argv) < 2:
            print("herdr wrapper: wrapper path is required", file=sys.stderr)
            return 127
        return wrapper_main(argv[1], argv[2:])

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

    try:
        apply_creator_edges(tree, load_creator_edges(server_scope()))
    except RegistryError as error:
        print(f"herdr-resource-tree: provenance lookup failed: {error}", file=sys.stderr)
        return 1

    if args.branch:
        try:
            caller = identify_caller("herdr")
        except (OSError, SnapshotError) as error:
            print(
                f"herdr-resource-tree: caller identity unavailable: {error}",
                file=sys.stderr,
            )
            return 1
        if caller is None:
            print(
                "herdr-resource-tree: caller identity unavailable: current pane has no agent session",
                file=sys.stderr,
            )
            return 1
        tree = filter_creator_branch(tree, caller["session"])

    if args.json:
        print(json.dumps(tree, ensure_ascii=False, indent=2))
    else:
        print(render_human(tree))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
