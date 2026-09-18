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


class CreatedResourcesError(SnapshotError):
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
    return (
        f"socket:{socket_path}:{socket_identity.st_dev}:{socket_identity.st_ino}:"
        f"{socket_identity.st_ctime_ns}"
    )


def require_server_scope(expected):
    if server_scope() != expected:
        raise RegistryError("server identity changed during snapshot retrieval")


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
        connection.execute("BEGIN IMMEDIATE")
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS operations (
                operation_id TEXT PRIMARY KEY,
                server_scope TEXT NOT NULL,
                caller_session TEXT NOT NULL,
                caller_pane_id TEXT NOT NULL,
                caller_terminal_id TEXT NOT NULL,
                creation_kind TEXT NOT NULL DEFAULT 'unknown',
                status TEXT NOT NULL,
                unresolved_reason TEXT,
                native_exit_status INTEGER,
                pane_id TEXT,
                terminal_id TEXT,
                workspace_id TEXT,
                tab_id TEXT,
                workspace_created INTEGER NOT NULL DEFAULT 0,
                tab_created INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        columns = {
            row[1] for row in connection.execute("PRAGMA table_info(operations)")
        }
        migrations = {
            "creation_kind": "TEXT NOT NULL DEFAULT 'unknown'",
            "unresolved_reason": "TEXT",
            "workspace_created": "INTEGER NOT NULL DEFAULT 0",
            "tab_created": "INTEGER NOT NULL DEFAULT 0",
        }
        for column, definition in migrations.items():
            if column not in columns:
                connection.execute(
                    f"ALTER TABLE operations ADD COLUMN {column} {definition}"
                )
        connection.execute(
            """
            CREATE INDEX IF NOT EXISTS operations_creator_lookup
            ON operations (server_scope, status, pane_id, terminal_id)
            """
        )
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS agent_parent_edges (
                server_scope TEXT NOT NULL,
                child_session TEXT NOT NULL,
                parent_session TEXT NOT NULL,
                child_name TEXT NOT NULL,
                parent_name TEXT NOT NULL,
                PRIMARY KEY (server_scope, child_session)
            )
            """
        )
        connection.execute(
            """
            CREATE INDEX IF NOT EXISTS agent_parent_lookup
            ON agent_parent_edges (server_scope, parent_session)
            """
        )
        connection.commit()
        if create:
            os.chmod(database, 0o600)
        return connection
    except (OSError, sqlite3.Error) as error:
        raise RegistryError(str(error)) from error


def record_intent(operation_id, scope, caller, creation_kind):
    connection = connect_registry(create=True)
    try:
        with connection:
            connection.execute(
                """
                INSERT INTO operations (
                    operation_id, server_scope, caller_session,
                    caller_pane_id, caller_terminal_id, creation_kind, status
                ) VALUES (?, ?, ?, ?, ?, ?, 'intent-recorded')
                """,
                (
                    operation_id,
                    scope,
                    json.dumps(caller["session"], sort_keys=True),
                    caller["pane_id"],
                    caller["terminal_id"],
                    creation_kind,
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


def record_uncertain_operation(operation_id, reason, resources=None):
    resources = resources or {}
    connection = connect_registry(create=True)
    try:
        with connection:
            connection.execute(
                """
                UPDATE operations
                SET status = 'unresolved', unresolved_reason = ?,
                    pane_id = ?, terminal_id = ?, workspace_id = ?, tab_id = ?
                WHERE operation_id = ? AND status = 'intent-recorded'
                """,
                (
                    reason,
                    resources.get("pane_id"),
                    resources.get("terminal_id"),
                    resources.get("workspace_id"),
                    resources.get("tab_id"),
                    operation_id,
                ),
            )
    except sqlite3.Error as error:
        raise RegistryError(str(error)) from error
    finally:
        connection.close()


def preserve_uncertain_operation(operation_id, detail, resources=None):
    try:
        record_uncertain_operation(operation_id, detail, resources)
    except RegistryError as error:
        return f"{detail}; unresolved state recording failed: {error}"
    return detail


def finalize_operation(operation_id, resources):
    if os.environ.get("HERDR_RESOURCE_TREE_TEST_FAIL_FINALIZE") == "1":
        raise RegistryError("injected finalization failure")
    connection = connect_registry(create=True)
    try:
        with connection:
            cursor = connection.execute(
                """
                UPDATE operations
                SET status = 'finalized', pane_id = ?, terminal_id = ?,
                    workspace_id = ?, tab_id = ?, workspace_created = ?,
                    tab_created = ?
                WHERE operation_id = ? AND status = 'intent-recorded'
                """,
                (
                    resources["pane_id"],
                    resources["terminal_id"],
                    resources["workspace_id"],
                    resources["tab_id"],
                    resources["workspace_created"],
                    resources["tab_created"],
                    operation_id,
                ),
            )
            if cursor.rowcount != 1:
                raise RegistryError("operation intent is no longer finalizable")
    except sqlite3.Error as error:
        raise RegistryError(str(error)) from error
    finally:
        connection.close()


def encode_session(session):
    return json.dumps(session, sort_keys=True, separators=(",", ":"))


def decode_stored_session(value, path):
    try:
        return normalize_session(json.loads(value), path)
    except (json.JSONDecodeError, SnapshotError) as error:
        raise RegistryError(str(error)) from error


def record_parent_edge(scope, parent_session, child_session, parent_name, child_name):
    parent_key = encode_session(parent_session)
    child_key = encode_session(child_session)
    if parent_key == child_key:
        raise RegistryError("an Agent session cannot be its own parent")

    connection = connect_registry(create=True)
    try:
        connection.execute("BEGIN IMMEDIATE")
        rows = connection.execute(
            """
            SELECT child_session, parent_session, child_name, parent_name
            FROM agent_parent_edges
            WHERE server_scope = ?
            """,
            (scope,),
        ).fetchall()
        by_child = {
            stored_child: (stored_parent, stored_child_name, stored_parent_name)
            for stored_child, stored_parent, stored_child_name, stored_parent_name in rows
        }
        existing = by_child.get(child_key)
        expected = (parent_key, child_name, parent_name)
        if existing is not None:
            if existing != expected:
                raise RegistryError("child Agent session already has a different parent edge")
            connection.commit()
            return

        ancestor = parent_key
        visited = set()
        while ancestor in by_child:
            if ancestor in visited:
                raise RegistryError("stored Agent parentage contains a cycle")
            visited.add(ancestor)
            ancestor = by_child[ancestor][0]
            if ancestor == child_key:
                raise RegistryError("Agent parent edge would create a cycle")

        connection.execute(
            """
            INSERT INTO agent_parent_edges (
                server_scope, child_session, parent_session, child_name, parent_name
            ) VALUES (?, ?, ?, ?, ?)
            """,
            (scope, child_key, parent_key, child_name, parent_name),
        )
        connection.commit()
    except sqlite3.Error as error:
        connection.rollback()
        raise RegistryError(str(error)) from error
    except RegistryError:
        connection.rollback()
        raise
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


def parse_created_resources(stdout, creation_kind):
    try:
        envelope = json.loads(stdout)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SnapshotError(f"native success response is not valid JSON: {error}") from error
    result = envelope.get("result") if isinstance(envelope, dict) else None
    if not isinstance(result, dict):
        raise SnapshotError("native success response has no result object")

    coordinates = {}
    first_error = None

    if creation_kind == "workspace":
        workspace = result.get("workspace")
        if not isinstance(workspace, dict):
            first_error = SnapshotError(
                "native success response has no result.workspace object"
            )
        else:
            try:
                coordinates["workspace_id"] = required_string(
                    workspace.get("workspace_id"), "created workspace workspace_id"
                )
            except SnapshotError as error:
                first_error = error

    if creation_kind in ("tab", "workspace"):
        tab = result.get("tab")
        if not isinstance(tab, dict):
            if first_error is None:
                first_error = SnapshotError(
                    "native success response has no result.tab object"
                )
        else:
            for key in ("workspace_id", "tab_id"):
                try:
                    value = required_string(tab.get(key), f"created tab {key}")
                    existing = coordinates.get(key)
                    if existing is not None and existing != value:
                        raise SnapshotError(
                            f"created tab {key} does not match returned container"
                        )
                    coordinates[key] = value
                except SnapshotError as error:
                    if first_error is None:
                        first_error = error

    pane_key = "pane" if creation_kind == "pane" else "root_pane"
    pane = result.get(pane_key)
    if not isinstance(pane, dict):
        if first_error is None:
            first_error = SnapshotError(
                f"native success response has no result.{pane_key} object"
            )
        pane = {}
    for key in ("pane_id", "terminal_id", "workspace_id", "tab_id"):
        try:
            value = required_string(pane.get(key), f"created pane {key}")
            existing = coordinates.get(key)
            if existing is not None and existing != value:
                raise SnapshotError(
                    f"created pane {key} does not match returned container"
                )
            coordinates[key] = value
        except SnapshotError as error:
            if first_error is None:
                first_error = error
    if first_error is not None:
        raise CreatedResourcesError(str(first_error), coordinates) from first_error
    return {
        **coordinates,
        "workspace_created": int(creation_kind == "workspace"),
        "tab_created": int(creation_kind in ("tab", "workspace")),
    }


def write_native_output(completed):
    sys.stdout.buffer.write(completed.stdout)
    sys.stdout.buffer.flush()
    sys.stderr.buffer.write(completed.stderr)
    sys.stderr.buffer.flush()


def report_untracked_creation(operation_id, resources, detail):
    coordinates = ""
    if resources:
        coordinates = " " + " ".join(
            f"{key}={value}" for key, value in resources.items()
        )
    print(
        f"herdr wrapper: creation operation {operation_id}{coordinates} succeeded, "
        f"but provenance finalization failed: {detail}; created resources remain open "
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


def managed_creation(original, argv, caller, creation_kind, scope):
    operation_id = str(uuid.uuid4())
    try:
        record_intent(operation_id, scope, caller, creation_kind)
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
        detail = "native creation timed out after 30 seconds"
        detail = preserve_uncertain_operation(operation_id, detail)
        report_uncertain_creation(operation_id, detail)
        return 124
    write_native_output(completed)
    if completed.returncode != 0:
        if completed.returncode < 0:
            exit_status = 128 - completed.returncode
            detail = f"native creation terminated by signal {-completed.returncode}"
            detail = preserve_uncertain_operation(operation_id, detail)
            report_uncertain_creation(operation_id, detail)
            return exit_status
        record_native_failure(operation_id, completed.returncode)
        return completed.returncode

    resources = None
    try:
        resources = parse_created_resources(completed.stdout, creation_kind)
        require_server_scope(scope)
        finalize_operation(operation_id, resources)
    except CreatedResourcesError as error:
        resources = error.coordinates
        detail = preserve_uncertain_operation(operation_id, str(error), resources)
        report_untracked_creation(operation_id, resources, detail)
        return 70
    except (SnapshotError, RegistryError) as error:
        detail = preserve_uncertain_operation(operation_id, str(error), resources)
        report_untracked_creation(operation_id, resources, detail)
        return 70
    return 0


def wrapper_main(wrapper_path, argv):
    try:
        original = find_original_herdr(wrapper_path)
    except OSError as error:
        if argv == ["--version"] and os.environ.get("HERDR_WRAPPER_REQUIRE_NATIVE") != "1":
            print("herdr wrapper: native herdr unavailable")
            return 0
        print(f"herdr wrapper: {error}", file=sys.stderr)
        return 127
    creation_kind = {
        ("pane", "split"): "pane",
        ("tab", "create"): "tab",
        ("workspace", "create"): "workspace",
    }.get(tuple(argv[:2]))
    if creation_kind is not None and not any(
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
            try:
                scope = server_scope()
                verified_caller = identify_caller(original)
                require_server_scope(scope)
            except (OSError, SnapshotError, RegistryError) as error:
                print(
                    "herdr wrapper: caller identity could not be revalidated; native "
                    f"creation was not called: {error}",
                    file=sys.stderr,
                )
                return 69
            if verified_caller != caller:
                print(
                    "herdr wrapper: caller identity changed during verification; native "
                    "creation was not called",
                    file=sys.stderr,
                )
                return 69
            return managed_creation(
                original, argv, caller, creation_kind, scope
            )
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
    terminal_ids = set()
    for pane_id, (pane, path) in pane_index.items():
        terminal_id = required_string(pane.get("terminal_id"), f"{path}.terminal_id")
        if terminal_id in terminal_ids:
            raise SnapshotError(f"duplicate terminal_id {terminal_id!r}")
        terminal_ids.add(terminal_id)

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
            "parent_name": None,
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
        "schema_version": 3,
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
        return {"workspaces": {}, "tabs": {}, "panes": {}}
    try:
        rows = connection.execute(
            """
            SELECT workspace_id, tab_id, pane_id, terminal_id,
                   workspace_created, tab_created, caller_session
            FROM operations
            WHERE server_scope = ? AND status = 'finalized'
            """,
            (scope,),
        ).fetchall()
    except sqlite3.Error as error:
        raise RegistryError(str(error)) from error
    finally:
        connection.close()

    edges = {"workspaces": {}, "tabs": {}, "panes": {}}
    for (
        workspace_id,
        tab_id,
        pane_id,
        terminal_id,
        workspace_created,
        tab_created,
        encoded_session,
    ) in rows:
        try:
            session = normalize_session(
                json.loads(encoded_session),
                f"stored creator for pane {pane_id!r}",
            )
        except (json.JSONDecodeError, SnapshotError) as error:
            raise RegistryError(str(error)) from error
        resource_keys = [("panes", terminal_id)]
        if workspace_created:
            resource_keys.append(("workspaces", workspace_id))
        if tab_created:
            resource_keys.append(("tabs", tab_id))
        for kind, key in resource_keys:
            if key in edges[kind] and edges[kind][key] != session:
                raise RegistryError(f"conflicting creator records for {kind[:-1]} {key!r}")
            edges[kind][key] = session
    return edges


def load_unresolved_operations(scope):
    connection = connect_registry(create=False)
    if connection is None:
        return []
    try:
        rows = connection.execute(
            """
            SELECT operation_id, creation_kind, caller_session,
                   unresolved_reason, workspace_id, tab_id, pane_id, terminal_id
            FROM operations
            WHERE server_scope = ? AND status IN ('intent-recorded', 'unresolved')
            ORDER BY operation_id
            """,
            (scope,),
        ).fetchall()
    except sqlite3.Error as error:
        raise RegistryError(str(error)) from error
    finally:
        connection.close()

    operations = []
    for (
        operation_id,
        creation_kind,
        encoded_session,
        reason,
        workspace_id,
        tab_id,
        pane_id,
        terminal_id,
    ) in rows:
        known_resources = {
            key: value
            for key, value in (
                ("workspace_id", workspace_id),
                ("tab_id", tab_id),
                ("pane_id", pane_id),
                ("terminal_id", terminal_id),
            )
            if value is not None
        }
        operations.append(
            {
                "operation_id": operation_id,
                "creation_kind": creation_kind,
                "caller_session": decode_stored_session(
                    encoded_session, f"stored caller for operation {operation_id!r}"
                ),
                "reason": reason
                or "creation ended before a final native outcome was recorded",
                "known_resources": known_resources,
                "retry_safe": False,
            }
        )
    return operations


def apply_creator_edges(tree, edges):
    for workspace in tree["workspaces"]:
        workspace["creator_session"] = edges["workspaces"].get(workspace["id"])
        for tab in workspace["tabs"]:
            tab["creator_session"] = edges["tabs"].get(tab["id"])
            for pane in tab["panes"]:
                pane["creator_session"] = edges["panes"].get(pane["terminal_id"])


def load_parent_edges(scope):
    connection = connect_registry(create=False)
    if connection is None:
        return {}
    try:
        rows = connection.execute(
            """
            SELECT child_session, parent_session, child_name, parent_name
            FROM agent_parent_edges
            WHERE server_scope = ?
            ORDER BY child_session
            """,
            (scope,),
        ).fetchall()
    except sqlite3.Error as error:
        raise RegistryError(str(error)) from error
    finally:
        connection.close()

    edges = {}
    for encoded_child, encoded_parent, child_name, parent_name in rows:
        child = decode_stored_session(encoded_child, "stored child Agent session")
        parent = decode_stored_session(encoded_parent, "stored parent Agent session")
        if not isinstance(child_name, str) or not child_name:
            raise RegistryError("stored child Agent name must be a non-empty string")
        if not isinstance(parent_name, str) or not parent_name:
            raise RegistryError("stored parent Agent name must be a non-empty string")
        child_key = encode_session(child)
        if child_key in edges:
            raise RegistryError("child Agent session has conflicting parent edges")
        edges[child_key] = {
            "child_session": child,
            "child_name": child_name,
            "parent_session": parent,
            "parent_name": parent_name,
        }
    return edges


def iter_agents(tree):
    for workspace in tree["workspaces"]:
        for tab in workspace["tabs"]:
            for pane in tab["panes"]:
                if pane["agent"] is not None:
                    yield pane["agent"]


def active_parent_edges(tree, edges):
    anchors = {
        encode_session(agent["session"])
        for agent in iter_agents(tree)
        if agent["session"] is not None
    }
    for workspace in tree["workspaces"]:
        if workspace["creator_session"] is not None:
            anchors.add(encode_session(workspace["creator_session"]))
        for tab in workspace["tabs"]:
            if tab["creator_session"] is not None:
                anchors.add(encode_session(tab["creator_session"]))
            for pane in tab["panes"]:
                if pane["creator_session"] is not None:
                    anchors.add(encode_session(pane["creator_session"]))

    active = {}
    for anchor in anchors:
        current = anchor
        visited = set()
        while current in edges:
            if current in visited:
                raise RegistryError("stored Agent parentage contains a cycle")
            visited.add(current)
            edge = edges[current]
            active[current] = edge
            current = encode_session(edge["parent_session"])
    return active


def find_pane(tree, pane_id):
    for workspace in tree["workspaces"]:
        for tab in workspace["tabs"]:
            for pane in tab["panes"]:
                if pane["id"] == pane_id:
                    return pane
    return None


def apply_parent_edges(tree, edges):
    for agent in iter_agents(tree):
        session = agent["session"]
        edge = edges.get(encode_session(session)) if session is not None else None
        agent["parent_session"] = edge["parent_session"] if edge else None
        agent["parent_name"] = edge["parent_name"] if edge else None


def build_branch(tree, session, edges):
    session_key = encode_session(session)
    children = {}
    for edge in edges.values():
        parent_key = encode_session(edge["parent_session"])
        children.setdefault(parent_key, []).append(edge)
    for values in children.values():
        values.sort(key=lambda edge: encode_session(edge["child_session"]))

    descendants = []
    descendant_keys = set()
    frontier = list(children.get(session_key, []))
    while frontier:
        edge = frontier.pop(0)
        child_key = encode_session(edge["child_session"])
        if child_key in descendant_keys or child_key == session_key:
            raise RegistryError("stored Agent parentage contains a cycle")
        descendant_keys.add(child_key)
        descendants.append(
            {
                "presentation_name": edge["child_name"],
                "session": edge["child_session"],
                "parent_session": edge["parent_session"],
            }
        )
        frontier.extend(children.get(child_key, []))

    current_name = None
    for agent in iter_agents(tree):
        if agent["session"] == session:
            current_name = agent["presentation_name"]
            break
    if current_name is None and session_key in edges:
        current_name = edges[session_key]["child_name"]

    parent_edge = edges.get(session_key)
    parent = None
    if parent_edge is not None:
        parent = {
            "presentation_name": parent_edge["parent_name"],
            "session": parent_edge["parent_session"],
        }
    return {
        "session": session,
        "presentation_name": current_name,
        "parent": parent,
        "descendants": descendants,
    }, {session_key, *descendant_keys}


def filter_creator_branch(tree, creator_keys):
    workspaces = []
    for workspace in tree["workspaces"]:
        tabs = []
        for tab in workspace["tabs"]:
            panes = [
                pane
                for pane in tab["panes"]
                if pane["creator_session"] is not None
                and encode_session(pane["creator_session"]) in creator_keys
            ]
            tab_created = (
                tab["creator_session"] is not None
                and encode_session(tab["creator_session"]) in creator_keys
            )
            if tab_created or panes:
                tabs.append({**tab, "panes": panes})
        workspace_created = (
            workspace["creator_session"] is not None
            and encode_session(workspace["creator_session"]) in creator_keys
        )
        if workspace_created or tabs:
            workspaces.append({**workspace, "tabs": tabs})
    return {**tree, "workspaces": workspaces}


def filter_unresolved_operations(operations, creator_keys):
    return [
        operation
        for operation in operations
        if encode_session(operation["caller_session"]) in creator_keys
    ]


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
    lines = []
    branch = tree.get("branch")
    if branch is not None:
        lines.append(
            f"Agent branch: {display_label(branch['presentation_name'])} "
            f"[{display_session(branch['session'])}]"
        )
        if branch["parent"] is not None:
            lines.append(
                f"Parent agent: {display_label(branch['parent']['presentation_name'])} "
                f"[{display_session(branch['parent']['session'])}]"
            )
        for descendant in branch["descendants"]:
            lines.append(
                f"Descendant agent: {display_label(descendant['presentation_name'])} "
                f"[{display_session(descendant['session'])}]"
            )
    lines.append(
        f"local Herdr server (version {scope['version']}, protocol {scope['protocol']})"
    )
    if not tree["workspaces"]:
        lines.append("(no open workspaces)")
    else:
        for workspace in tree["workspaces"]:
            lines.append(
                f"workspace {display_label(workspace['label'])} [{workspace['id']}]"
            )
            lines.append(f"  creator: {display_session(workspace['creator_session'])}")
            for tab in workspace["tabs"]:
                lines.append(f"  tab {display_label(tab['label'])} [{tab['id']}]")
                lines.append(f"    creator: {display_session(tab['creator_session'])}")
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
                    if agent["parent_session"] is None:
                        lines.append("      parent: unknown")
                    else:
                        lines.append(
                            f"      parent: {display_label(agent['parent_name'])} "
                            f"({display_session(agent['parent_session'])})"
                        )
    for operation in tree["unresolved_operations"]:
        lines.append(
            f"unresolved {operation['creation_kind']} creation operation "
            f"{operation['operation_id']}: automatic retry is unsafe"
        )
        if operation["known_resources"]:
            lines.append(
                "  known resources: "
                + " ".join(
                    f"{key}={value}"
                    for key, value in operation["known_resources"].items()
                )
            )
        lines.append(f"  reason: {operation['reason']}")
    return "\n".join(lines)


def context_limit():
    raw = os.environ.get("HERDR_RESOURCE_CONTEXT_MAX_CHARS", "4096")
    try:
        limit = int(raw)
    except ValueError as error:
        raise ValueError("HERDR_RESOURCE_CONTEXT_MAX_CHARS must be an integer") from error
    if not 256 <= limit <= 16384:
        raise ValueError(
            "HERDR_RESOURCE_CONTEXT_MAX_CHARS must be between 256 and 16384"
        )
    return limit


def render_context(tree, limit):
    branch = tree["branch"]
    lines = []
    parent = branch["parent"]
    if parent is not None:
        lines.append(f"Parent agent: {display_label(parent['presentation_name'])}")
    for descendant in branch["descendants"]:
        lines.append(
            f"Descendant agent: {display_label(descendant['presentation_name'])} "
            f"[{display_session(descendant['session'])}]"
        )

    if tree["workspaces"]:
        lines.append("Resources:")
        for workspace in tree["workspaces"]:
            lines.append(
                f"- workspace {display_label(workspace['label'])} [{workspace['id']}] "
                f"creator={display_session(workspace['creator_session'])}"
            )
            for tab in workspace["tabs"]:
                lines.append(
                    f"  - tab {display_label(tab['label'])} [{tab['id']}] "
                    f"creator={display_session(tab['creator_session'])}"
                )
                for pane in tab["panes"]:
                    lines.append(
                        f"    - pane {display_label(pane['label'])} [{pane['id']}] "
                        f"terminal={pane['terminal_id']} "
                        f"creator={display_session(pane['creator_session'])}"
                    )
                    agent = pane["agent"]
                    if agent is not None:
                        parent_link = display_session(agent["parent_session"])
                        if agent["parent_name"] is not None:
                            parent_link = (
                                f"{display_label(agent['parent_name'])} [{parent_link}]"
                            )
                        lines.append(
                            f"      occupant={agent['client']} "
                            f"{display_label(agent['presentation_name'])} "
                            f"session={display_session(agent['session'])} "
                            f"parent={parent_link}"
                        )
    if tree["unresolved_operations"]:
        lines.append("Unresolved creations (automatic retry is unsafe):")
        for operation in tree["unresolved_operations"]:
            lines.append(
                f"- {operation['creation_kind']} operation "
                f"{operation['operation_id']} reason={operation['reason']}"
            )

    full = "\n".join(lines)
    if len(full) <= limit:
        return full

    marker = "Context truncated. Full branch: `herdr-resource-tree --branch`."
    kept = []
    used = len(marker)
    for line in lines:
        additional = len(line) + 1
        if used + additional > limit:
            break
        kept.append(line)
        used += additional
    kept.append(marker)
    return "\n".join(kept)


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


def snapshot_failure_detail(completed):
    return (
        completed.stderr.strip()
        or completed.stdout.strip()
        or f"herdr exited with status {completed.returncode}"
    )


def parse_record_child_args(argv):
    parser = argparse.ArgumentParser(
        prog="herdr-resource-tree record-child",
        description="Record verified managed Agent parentage.",
    )
    parser.add_argument("--pane", required=True, help="the launched child pane ID")
    parser.add_argument(
        "--terminal", required=True, help="the launched child terminal identity"
    )
    parser.add_argument(
        "--child-name", required=True, help="the verified launched Agent name"
    )
    parser.add_argument(
        "--child-session-json",
        required=True,
        help="the verified launched Agent session identity",
    )
    return parser.parse_args(argv)


def record_child_main(argv):
    args = parse_record_child_args(argv)
    try:
        expected_child_session = normalize_session(
            json.loads(args.child_session_json), "verified child Agent session"
        )
    except (json.JSONDecodeError, SnapshotError) as error:
        print(f"herdr-resource-tree: parentage verification failed: {error}", file=sys.stderr)
        return 1
    try:
        scope = server_scope()
    except RegistryError as error:
        print(
            f"herdr-resource-tree: parentage scope unavailable: {error}",
            file=sys.stderr,
        )
        return 1
    try:
        caller = identify_caller("herdr")
    except (OSError, SnapshotError) as error:
        print(
            f"herdr-resource-tree: parent identity unavailable: {error}",
            file=sys.stderr,
        )
        return 1
    if caller is None:
        print(
            "herdr-resource-tree: parent identity unavailable: current pane has no Agent session",
            file=sys.stderr,
        )
        return 1

    try:
        completed = retrieve_snapshot()
    except SnapshotTimeout as error:
        print(f"herdr-resource-tree: parentage snapshot failed: {error}", file=sys.stderr)
        return 124
    except OSError as error:
        print(f"herdr-resource-tree: parentage snapshot failed: {error}", file=sys.stderr)
        return 1
    if completed.returncode != 0:
        print(
            "herdr-resource-tree: parentage snapshot failed: "
            f"{snapshot_failure_detail(completed)}",
            file=sys.stderr,
        )
        return completed.returncode if 1 <= completed.returncode <= 125 else 1

    try:
        tree = normalize_snapshot(json.loads(completed.stdout))
        require_server_scope(scope)
        apply_creator_edges(tree, load_creator_edges(scope))
        pane = find_pane(tree, args.pane)
        if pane is None:
            raise SnapshotError(f"launched child pane {args.pane!r} is not live")
        if pane["terminal_id"] != args.terminal:
            raise SnapshotError("launched child pane terminal identity changed")
        if pane["creator_session"] != caller["session"]:
            raise SnapshotError(
                "launched child pane was not created by the current parent session"
            )
        child = pane["agent"]
        if child is None or child["session"] is None:
            raise SnapshotError("launched child Agent session is unavailable")
        if (
            child["presentation_name"] != args.child_name
            or child["session"] != expected_child_session
        ):
            raise SnapshotError("launched child identity changed before parentage recording")

        parents = [
            agent for agent in iter_agents(tree) if agent["session"] == caller["session"]
        ]
        if len(parents) != 1:
            raise SnapshotError("current parent session is not uniquely observable")
        parent = parents[0]
        record_parent_edge(
            scope,
            caller["session"],
            child["session"],
            parent["presentation_name"],
            child["presentation_name"],
        )
    except (json.JSONDecodeError, SnapshotError) as error:
        print(f"herdr-resource-tree: parentage verification failed: {error}", file=sys.stderr)
        return 1
    except RegistryError as error:
        print(f"herdr-resource-tree: parentage recording failed: {error}", file=sys.stderr)
        return 1

    print(
        json.dumps(
            {
                "parent": {
                    "presentation_name": parent["presentation_name"],
                    "session": caller["session"],
                },
                "child": {
                    "presentation_name": child["presentation_name"],
                    "session": child["session"],
                    "pane": pane["id"],
                    "terminal": pane["terminal_id"],
                },
            },
            ensure_ascii=False,
            separators=(",", ":"),
        )
    )
    return 0


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
        help="show only resources created by the invoking agent session",
    )
    parser.add_argument(
        "--context",
        action="store_true",
        help="emit bounded Agent resource context for a client adapter",
    )
    parser.add_argument(
        "--caller-agent",
        help="require the invoking Agent session to use this client",
    )
    parser.add_argument(
        "--caller-session-id",
        help="require the invoking Agent session to have this native id",
    )
    args = parser.parse_args(argv)
    if args.context and args.json:
        parser.error("--context cannot be combined with --json")
    if bool(args.caller_agent) != bool(args.caller_session_id):
        parser.error("--caller-agent and --caller-session-id must be used together")
    if args.caller_agent and not args.context:
        parser.error("caller identity guards require --context")
    return args


def main(argv):
    if argv and argv[0] == "--wrap":
        if len(argv) < 2:
            print("herdr wrapper: wrapper path is required", file=sys.stderr)
            return 127
        return wrapper_main(argv[1], argv[2:])
    if argv and argv[0] == "record-child":
        return record_child_main(argv[1:])

    args = parse_args(argv)
    try:
        scope = server_scope()
    except RegistryError as error:
        print(f"herdr-resource-tree: provenance lookup failed: {error}", file=sys.stderr)
        return 1
    try:
        completed = retrieve_snapshot()
    except SnapshotTimeout as error:
        print(f"herdr-resource-tree: snapshot retrieval failed: {error}", file=sys.stderr)
        return 124
    except OSError as error:
        print(f"herdr-resource-tree: snapshot retrieval failed: {error}", file=sys.stderr)
        return 1

    if completed.returncode != 0:
        detail = snapshot_failure_detail(completed)
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
        require_server_scope(scope)
        apply_creator_edges(tree, load_creator_edges(scope))
        tree["unresolved_operations"] = load_unresolved_operations(scope)
        parent_edges = active_parent_edges(tree, load_parent_edges(scope))
        apply_parent_edges(tree, parent_edges)
    except RegistryError as error:
        print(f"herdr-resource-tree: provenance lookup failed: {error}", file=sys.stderr)
        return 1

    if args.branch or args.context:
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
        if args.caller_agent and (
            caller["session"]["agent"] != args.caller_agent
            or caller["session"]["value"] != args.caller_session_id
        ):
            print(
                "herdr-resource-tree: caller identity changed before context projection",
                file=sys.stderr,
            )
            return 1
        try:
            branch, creator_keys = build_branch(tree, caller["session"], parent_edges)
            tree = filter_creator_branch(tree, creator_keys)
            tree["unresolved_operations"] = filter_unresolved_operations(
                tree["unresolved_operations"], creator_keys
            )
            tree["branch"] = branch
        except RegistryError as error:
            print(f"herdr-resource-tree: parentage lookup failed: {error}", file=sys.stderr)
            return 1

    try:
        require_server_scope(scope)
    except RegistryError as error:
        print(f"herdr-resource-tree: provenance lookup failed: {error}", file=sys.stderr)
        return 1

    if args.context:
        try:
            context = render_context(tree, context_limit())
        except ValueError as error:
            print(f"herdr-resource-tree: context configuration failed: {error}", file=sys.stderr)
            return 2
        if context:
            print(context)
    elif args.json:
        print(json.dumps(tree, ensure_ascii=False, indent=2))
    else:
        print(render_human(tree))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
