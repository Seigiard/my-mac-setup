#!/usr/bin/env python3
"""Intercom admission and durable recovery of launch claims.

It owns enrollment decisions, deferred-rename notes and claim cleanup intents.
It never supervises a client.
"""

from __future__ import annotations

import argparse
from typing import NamedTuple
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
import plistlib
import re
import shutil
import socket
import struct
import subprocess
import sys
import time
import uuid


POLL_SECONDS = 0.10
PENDING_RETRY_SECONDS = 2.0
ARCHIVE_MAX_AGE_SECONDS = 7 * 24 * 60 * 60
ARCHIVE_MAX_RECORDS = 1000
ARCHIVE_PRUNE_SECONDS = 60
IDENTITY_FORMAT = "ps-lstart-c-utc-v1"
CLAIM_SOURCE = "herdr-agent-intercom-recovery-v1"


class ProcessObservation(NamedTuple):
    outcome: str
    identity: str | None = None
    reason: str | None = None
    state: str | None = None


class Host:
    """OS evidence. Start tokens retain ps lstart's one-second precision."""

    wall_time = staticmethod(time.time)
    wall_time_ns = staticmethod(time.time_ns)
    monotonic = staticmethod(time.monotonic)
    sleep = staticmethod(time.sleep)
    pid = staticmethod(os.getpid)
    parent_pid = staticmethod(os.getppid)

    def alias_candidates(self, seed):
        allocator = os.environ.get("HERDR_ALIAS_ALLOCATOR", "herdr-pane-labels")
        if allocator == "herdr-pane-labels" and not shutil.which(allocator):
            allocator = os.path.expanduser("~/.local/bin/herdr-pane-labels")
        result = subprocess.run([allocator, "--alias-candidates", seed], text=True,
                                capture_output=True, timeout=10, check=False)
        candidates = result.stdout.splitlines()
        if result.returncode or not candidates or any(
                not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", name) or
                name.startswith("unnamed-") for name in candidates):
            raise RecoveryError("alias allocator unavailable")
        return list(dict.fromkeys(candidates))

    def ensure_owner(self, root):
        label = os.environ.get("HERDR_AGENT_INTERCOM_RECOVERY_LABEL",
                               "com.seigiard.herdr-agent-intercom-recovery")
        plist = os.environ.get("HERDR_AGENT_INTERCOM_RECOVERY_PLIST",
                               os.path.expanduser(f"~/Library/LaunchAgents/{label}.plist"))
        return ensure_owner(root, label, plist, host=self)

    def process(self, pid):
        if not isinstance(pid, int) or pid <= 0:
            return ProcessObservation("unknown", reason="invalid_pid")
        try:
            result = subprocess.run(
                ["ps", "-p", str(pid), "-o", "lstart=", "-o", "stat="],
                text=True, capture_output=True, check=False, timeout=2,
                env={**os.environ, "LC_ALL": "C", "TZ": "UTC"},
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            return ProcessObservation("unknown", reason=f"process_lookup_unavailable: {error}")
        fields = result.stdout.split()
        if result.returncode == 0 and len(fields) == 6:
            token, state = " ".join(fields[:-1]), fields[-1]
            return ProcessObservation("exited" if state.startswith("Z") else "alive", token, state=state)
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return ProcessObservation("exited", reason="process_absent")
        except OSError as error:
            return ProcessObservation("unknown", reason=f"process_liveness_unknown: {error}")
        return ProcessObservation("unknown", reason="process_lookup_failed")

    def start_identity(self, pid):
        observed = self.process(pid)
        if observed.outcome == "unknown":
            raise RecoveryError(observed.reason)
        return observed.identity if observed.outcome == "alive" else None

    def parent(self, pid):
        try:
            result = subprocess.run(["ps", "-p", str(pid), "-o", "ppid=,comm="],
                                    text=True, capture_output=True, check=False, timeout=2,
                                    env={**os.environ, "LC_ALL": "C", "TZ": "UTC"})
            if not result.returncode:
                parent, command = result.stdout.strip().split(None, 1)
                return int(parent), command
        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
            raise RecoveryError(f"process ancestry unavailable: {error}") from error
        raise RecoveryError("process ancestry unavailable")


HOST = Host()


class Phase:
    INTENT = "intent"
    ACQUIRED = "acquired"
    SETTLED = "settled"
    RETIRED = "retired"
    ACTIVE = frozenset((INTENT, ACQUIRED))
    TERMINAL = frozenset((SETTLED, RETIRED))
    ALLOWED = {
        INTENT: frozenset((INTENT, ACQUIRED, SETTLED, RETIRED)),
        ACQUIRED: frozenset((ACQUIRED, SETTLED, RETIRED)),
        SETTLED: frozenset((SETTLED,)),
        RETIRED: frozenset((RETIRED,)),
    }


class Observation(NamedTuple):
    phase: str | None
    outcome: str
    reason_code: str
    next_attempt_deadline: float | None = None
    deadline_clock: str | None = None


class Launch(NamedTuple):
    kind: str
    route: str | None = None
    alias: str | None = None
    reason_code: str = "ok"


class Admission(NamedTuple):
    launch: Launch
    intent_id: str | None = None

    def tsv(self):
        launch = self.launch
        if launch.kind == "enrolled":
            if (launch.route not in {"claimed", "reused", "deferred_rename"} or
                    not launch.alias or (launch.route == "claimed") != bool(self.intent_id) or
                    launch.reason_code != "ok"):
                raise RecoveryError("invalid enrolled result")
        elif launch.kind != "native" or launch.route is not None or launch.alias is not None:
            raise RecoveryError("invalid native result")
        fields = ("v1", launch.kind, launch.route or "-", launch.alias or "-",
                  self.intent_id or "-", launch.reason_code)
        if any(not re.fullmatch(r"[A-Za-z0-9_-]+", field) for field in fields):
            raise RecoveryError("invalid admission field")
        return "\t".join(fields)


class RecoveryRoot:
    """The recovery store layout, separate from the Intercom broker runtime."""

    def __init__(self, root):
        self.root = os.path.realpath(root)
        self.intents = os.path.join(self.root, "intents")
        self.ready = os.path.join(self.root, "observer.ready")
        self.receipt = os.path.join(self.root, "observer.pid.json")
        self.owner_lock = os.path.join(self.root, "owner-admission")


class RecoveryEngine:
    """Recovery operations addressed by a state root and opaque intent handles."""

    def __init__(self, state_root, *, host=None, sessions=None):
        self.store = RecoveryRoot(state_root)
        self.state_root = self.store.root
        self.intent_dir = self.store.intents
        self.host = host if host is not None else HOST
        self.sessions = sessions if sessions is not None else HerdrSessions(self.host)

    def _path(self, intent_id):
        if not isinstance(intent_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", intent_id):
            raise RecoveryError("invalid intent ID")
        return os.path.join(self.intent_dir, intent_id + ".json")

    def admit(self, *, socket_path, pane_id, agent, launcher_pid):
        """Return a finished launch decision, independently of recovery ownership."""
        if agent not in {"claude", "opencode", "pi"} or not isinstance(launcher_pid, int) or launcher_pid <= 0:
            raise RecoveryError("invalid admission request")
        intent_id = None
        try:
            start = launcher_identity(launcher_pid, self.host)
            if not socket_path or not pane_id:
                raise RecoveryError("current Herdr pane or socket is unavailable")
            connection = self.sessions.connect(socket_path)
            scope = {"connection": connection}
            session = self.sessions(scope)
            response = session.request("pane.get", {"pane_id": pane_id})
            pane = response["result"]["pane"]
            if pane["pane_id"] != pane_id or not pane["terminal_id"]:
                raise RecoveryError("launch terminal identity is unavailable")
            scope["terminal"] = {"pane_id": pane_id, "terminal_id": pane["terminal_id"]}
            seed = f"{socket_path}|{pane_id}|{agent}|{launcher_pid}|{self.host.wall_time_ns()}"
            candidates = self.host.alias_candidates(seed)
            state = session.agent_state(pane)
            if "error" not in state:
                record = state["result"]["agent"]
                name = record.get("name")
                if (record.get("pane_id") != pane_id or record.get("terminal_id") != pane["terminal_id"] or
                        name not in candidates):
                    return Admission(Launch("native", reason_code="alias_unavailable"))
                name = self._reuse_alias(session, name)
                if name:
                    return Admission(Launch("enrolled", "reused", name))
                pane = session.locate_terminal()
                if pane is None:
                    raise RecoveryError("launch terminal disappeared")
            elif state["error"].get("code") != "agent_not_found":
                raise RecoveryError("agent lookup failed")

            # Used panes cannot accept a declaration. Only Claude can reconcile
            # its deferred name through the existing first-prompt hook.
            if pane.get("agent_session") is not None:
                if agent != "claude":
                    return Admission(Launch("native", reason_code="used_pane"))
            else:
                self.host.ensure_owner(self.state_root)

            occupied = session.request("agent.list", {})["result"]["agents"]
            if not isinstance(occupied, list) or any(not isinstance(item, dict) or "pane_id" not in item
                                                     for item in occupied):
                raise RecoveryError("malformed agent list")
            taken = {item.get("name") for item in occupied}
            candidates = [name for name in candidates if name not in taken]
            for alias in candidates[:3]:
                if self.host.start_identity(launcher_pid) != start:
                    raise RecoveryError("launcher incarnation changed during admission")
                if pane.get("agent_session") is not None:
                    self._defer_rename(pane["pane_id"], alias)
                    return Admission(Launch("enrolled", "deferred_rename", alias))
                claim = self._acquire(socket_path=socket_path, pane_id=pane["pane_id"], agent=agent,
                                      alias=alias, launcher_pid=launcher_pid, scope=scope, launcher_start=start)
                intent_id = claim["intent_id"] if claim.get("pending", claim["claimed"]) else None
                if claim["claimed"]:
                    return Admission(Launch("enrolled", "claimed", alias), intent_id)
                if claim.get("undeclarable"):
                    if agent != "claude":
                        return Admission(Launch("native", reason_code="used_pane"))
                    self._defer_rename(pane["pane_id"], alias)
                    return Admission(Launch("enrolled", "deferred_rename", alias))
                if not claim.get("retry"):
                    if intent_id:
                        print("admission unavailable: partial claim remains pending for recovery", file=sys.stderr)
                    else:
                        print("admission unavailable: the rejected claim was rolled back", file=sys.stderr)
                    return Admission(Launch("native", reason_code="acquisition_unconfirmed"), intent_id)
            return Admission(Launch("native", reason_code="alias_exhausted"))
        except (OSError, ValueError, KeyError, TypeError, RecoveryError, subprocess.TimeoutExpired) as error:
            print(f"admission unavailable: {error}", file=sys.stderr)
            return Admission(Launch("native", reason_code="admission_unavailable"), intent_id)

    def _defer_rename(self, pane_id, alias):
        directory = os.path.join(os.path.dirname(os.path.dirname(self.state_root)), "reconcile")
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, re.sub(r"[^A-Za-z0-9]", "_", pane_id))
        temporary = path + "." + uuid.uuid4().hex + ".tmp"
        try:
            with open(temporary, "x", encoding="utf-8") as handle:
                handle.write(alias + "\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, path)
            sync_directory(directory)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def _reuse_alias(self, session, expected_alias):
        scope = session.intent

        def pending():
            try:
                paths = active_intent_paths(self.intent_dir)
            except FileNotFoundError:
                return []
            obligations = []
            for path in paths:
                try:
                    intent = read_json(path)
                except FileNotFoundError:
                    continue
                if (intent["phase"] not in Phase.TERMINAL and
                        intent["connection"]["server_identity"] == scope["connection"]["server_identity"] and
                        intent["terminal"]["terminal_id"] == scope["terminal"]["terminal_id"]):
                    obligations.append(intent)
            return obligations

        obligations = pending()
        if obligations:
            for intent in obligations:
                if (intent.get("identity_format") != IDENTITY_FORMAT or
                        self.host.start_identity(intent["client"]["pid"]) == intent["client"]["start_identity"]):
                    raise RecoveryError("existing alias ownership is live or unverified")
            self.host.ensure_owner(self.state_root)
            deadline = self.host.monotonic() + 10
            while pending():
                if self.host.monotonic() >= deadline:
                    raise RecoveryError("existing alias cleanup remains pending")
                self.host.sleep(POLL_SECONDS)
        pane = session.locate_terminal()
        if pane is None:
            raise RecoveryError("existing alias terminal disappeared")
        response = session.agent_state(pane)
        if response.get("error", {}).get("code") == "agent_not_found":
            return None
        record = response["result"]["agent"]
        if record.get("terminal_id") != pane["terminal_id"] or record.get("name") != expected_alias:
            raise RecoveryError("existing alias changed during recovery")
        return expected_alias

    def _acquire(self, *, socket_path, pane_id, agent, alias, launcher_pid,
                 scope, launcher_start):
        return claim_intent(self.intent_dir, agent, CLAIM_SOURCE, alias, launcher_pid,
                            socket_path=socket_path, pane_id=pane_id, host=self.host,
                            sessions=self.sessions, scope=scope, launcher_start=launcher_start)

    def bind(self, intent_id, native_executable):
        """Bind cleanup to this PID; a missing executable leaves handoff disabled."""
        return bind_native_client(self._path(intent_id), host=self.host,
                                  native_executable=native_executable)

    def handoff(self, intent_id):
        request_handoff(self._path(intent_id), host=self.host, sessions=self.sessions)
        return self.observe_one(intent_id)

    def observe_one(self, intent_id):
        if not isinstance(intent_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", intent_id):
            return Observation(None, "unavailable", "invalid_intent_id")
        return observe_one(self._path(intent_id), host=self.host, sessions=self.sessions)


class RecoveryError(Exception):
    pass


class ServerInstanceChanged(RecoveryError):
    pass


class IntentBusy(RecoveryError):
    pass


@contextmanager
def intent_lock(path, timeout=0, create=False, host=HOST):
    """Late intent callers never recreate a removed sidecar at a new inode."""
    with open(str(path) + ".lock", "a" if create else "r+", encoding="utf-8") as handle:
        deadline = host.monotonic() + timeout
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError as error:
                if host.monotonic() >= deadline:
                    raise IntentBusy("intent update is in progress") from error
                host.sleep(POLL_SECONDS)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def atomic_write(path, value):
    directory = os.path.dirname(path)
    temporary = f"{path}.{os.getpid()}.{uuid.uuid4().hex}.tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
    directory_fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def read_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def archived_intent_path(path):
    return os.path.join(os.path.dirname(path), "archive", os.path.basename(path))


def read_intent(path):
    """Read a stable launch handle, including its immutable terminal receipt."""
    try:
        return read_json(path)
    except FileNotFoundError:
        return read_json(archived_intent_path(path))


def active_intent_paths(directory):
    return [os.path.join(directory, entry) for entry in sorted(os.listdir(directory))
            if entry.endswith(".json")]


def intent_handles(directory):
    """Diagnostic inventory; the observer scans only active_intent_paths."""
    active = set(active_intent_paths(directory))
    archive = os.path.join(directory, "archive")
    try:
        active.update(os.path.join(directory, entry) for entry in os.listdir(archive) if entry.endswith(".json"))
    except FileNotFoundError:
        pass
    return sorted(active)


def sync_directory(directory):
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def archive_terminal_intent(path):
    """Caller holds this intent's existing lock; the archived record is immutable."""
    intent = read_json(path)
    if intent["phase"] not in Phase.TERMINAL:
        return False
    destination = archived_intent_path(path)
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    os.replace(path, destination)
    sync_directory(os.path.dirname(destination))
    sync_directory(os.path.dirname(path))
    # Existing waiters keep the old inode. Later callers open r+, never create,
    # and all callers refuse terminal or absent records. This handle is never reused.
    os.unlink(str(path) + ".lock")
    sync_directory(os.path.dirname(path))
    return True


def prune_intent_archive(directory, now=None, max_age=ARCHIVE_MAX_AGE_SECONDS, max_records=ARCHIVE_MAX_RECORDS):
    archive = os.path.join(directory, "archive")
    try:
        entries = os.listdir(archive)
    except FileNotFoundError:
        return
    records = []
    for entry in entries:
        if not entry.endswith(".json"):
            continue
        path = os.path.join(archive, entry)
        try:
            records.append((os.stat(path).st_mtime, entry))
            # Complete a crash after the durable rename but before sidecar removal.
            if not os.path.exists(os.path.join(directory, entry)):
                try:
                    os.unlink(os.path.join(directory, entry + ".lock"))
                except FileNotFoundError:
                    pass
        except FileNotFoundError:
            continue
    cutoff = (HOST.wall_time() if now is None else now) - max_age
    changed = False
    for index, (modified, entry) in enumerate(sorted(records, reverse=True)):
        if modified < cutoff or index >= max_records:
            try:
                os.unlink(os.path.join(archive, entry))
                changed = True
            except FileNotFoundError:
                pass
    if changed:
        sync_directory(archive)


def peer_identity(connection, host=HOST):
    if sys.platform == "darwin":
        # LOCAL_PEERPID identifies the server attached to this connected descriptor.
        pid = struct.unpack("i", connection.getsockopt(0, 2, 4))[0]
    elif hasattr(socket, "SO_PEERCRED"):
        pid, _, _ = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    else:
        raise RecoveryError("connected-server identity is unavailable on this platform")
    start = host.start_identity(pid)
    if start is None:
        raise RecoveryError("connected server exited")
    return {"pid": pid, "start_identity": start}


def capture_server_identity(path, host=HOST):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(path)
        return peer_identity(connection, host)


def bound_request(intent, method, params, host=HOST):
    # Herdr closes each connection after one response. Validate the actual peer
    # on the descriptor used for the mutation; never reconnect after this check.
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(intent["connection"]["socket_path"])
        if peer_identity(connection, host) != intent["connection"]["server_identity"]:
            raise ServerInstanceChanged("server instance changed")
        request = {"id": uuid.uuid4().hex, "method": method, "params": params}
        connection.sendall((json.dumps(request) + "\n").encode())
        with connection.makefile("rb") as stream:
            line = stream.readline(1024 * 1024)
        if not line.endswith(b"\n"):
            raise RecoveryError("incomplete server response")
        response = json.loads(line)
        if response.get("id") != request["id"]:
            raise RecoveryError("server response identity mismatch")
        return response


def socket_identity(path):
    stat = os.stat(path)
    return {"device": stat.st_dev, "inode": stat.st_ino}


class HerdrSession:
    """Fenced transport and observed facts, without lifecycle decisions."""

    def __init__(self, intent, host=HOST):
        self.intent = intent
        self.host = host

    @staticmethod
    def connect(socket_path, host=HOST):
        return {"socket_path": socket_path,
                "server_identity": capture_server_identity(socket_path, host),
                "socket_identity": socket_identity(socket_path)}

    def request(self, method, params):
        return bound_request(self.intent, method, params, self.host)

    def locate_terminal(self):
        terminal = self.intent["terminal"]
        pane = self.request("pane.get", {"pane_id": terminal["pane_id"]})
        if "error" in pane and pane["error"].get("code") != "pane_not_found":
            raise RecoveryError(f"pane lookup failed: {pane['error']}")
        observed = pane.get("result", {}).get("pane", {})
        if observed.get("terminal_id") == terminal["terminal_id"]:
            return observed
        snapshot = self.request("session.snapshot", {})
        if "error" in snapshot:
            raise RecoveryError(f"terminal lookup failed: {snapshot['error']}")
        matches = [item for item in snapshot["result"]["snapshot"]["panes"]
                   if item.get("terminal_id") == terminal["terminal_id"]]
        if len(matches) > 1:
            raise RecoveryError("ambiguous terminal identity")
        return matches[0] if matches else None

    def agent_state(self, pane):
        return self.request("agent.get", {"target": pane["pane_id"]})

    def release_with_readback(self, sequence):
        # Resolve again immediately before mutation, including after a move.
        pane = self.locate_terminal()
        if pane is None:
            return None
        response = self.request("pane.release_agent", {
            "pane_id": pane["pane_id"], "source": self.intent["claim"]["source"],
            "agent": self.intent["agent_kind"], "seq": sequence,
        })
        if "error" in response:
            raise RecoveryError(f"release failed: {response['error']}")
        # A success response can be an ignored old sequence. Resolve the stable
        # terminal again so readback never mistakes the old location for absence.
        pane = self.locate_terminal()
        return self.agent_state(pane) if pane is not None else None

    def replacement(self):
        connection = self.intent["connection"]
        return HerdrSession({**self.intent, "connection": {**connection,
            "server_identity": capture_server_identity(connection["socket_path"], self.host)}}, self.host)


class HerdrSessions:
    """Session factory sharing the engine's host evidence reader."""

    def __init__(self, host):
        self.host = host

    def connect(self, socket_path):
        return HerdrSession.connect(socket_path, self.host)

    def __call__(self, intent):
        return HerdrSession(intent, self.host)


def write_intent(intent_dir, intent):
    """Durably record an unresolved obligation before the caller claims Herdr."""
    try:
        os.mkdir(intent_dir)
    except FileExistsError:
        pass
    # A terminal handle must never be reused, even after its archive expires.
    path = os.path.join(intent_dir, f"{intent['launch_id']}-{uuid.uuid4().hex}.json")
    with open(path + ".lock", "x", encoding="utf-8"):
        pass
    try:
        atomic_write(path, intent)
    except OSError:
        if not os.path.exists(path):
            os.unlink(path + ".lock")
        raise
    return path


def reserve_sequence(directory, source, host=HOST):
    """Persistently reserve claim, handoff and release sequence numbers per source."""
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, f"{source}.sequence.json")
    with intent_lock(path, timeout=5, create=True, host=host):
        try:
            previous = read_json(path)["last"]
        except FileNotFoundError:
            previous = -1
        candidate = max(host.wall_time_ns(), previous + 3)
        atomic_write(path, {"last": candidate + 2, "reserved_at_ns": host.wall_time_ns()})
        return candidate


def bind_native_client(path, *, host=HOST, native_executable):
    """Bind in the bridge's PID before exec, or refuse enrollment after cleanup."""
    try:
        return _bind_native_client(path, host=host, native_executable=native_executable)
    except FileNotFoundError:
        return False


def _bind_native_client(path, *, host=HOST, native_executable):
    with intent_lock(path, timeout=5, host=host):
        intent = read_intent(path)
        if intent["phase"] not in Phase.ACTIVE or "launcher_client" in intent:
            return False
        launcher = intent["client"]
        if intent.get("identity_format") != IDENTITY_FORMAT:
            return False
        if host.parent_pid() != launcher["pid"]:
            return False
        if host.start_identity(launcher["pid"]) != launcher["start_identity"]:
            return False
        start = host.start_identity(host.pid())
        if start is None:
            raise RecoveryError("native bridge process identity is unavailable")
        intent["launcher_client"] = launcher
        intent["client"] = {"pid": host.pid(), "start_identity": start}
        intent["native_executable"] = native_executable
        atomic_write(path, intent)
        return True


def require_client_ancestor(intent, host=HOST):
    """A first-prompt hook must descend from this native client, not a nested one."""
    expected = intent["client"]
    image = intent.get("native_executable")
    if not image:
        raise RecoveryError("handoff intent has no bound native client")
    if (intent.get("identity_format") != IDENTITY_FORMAT or
            host.start_identity(expected["pid"]) != expected["start_identity"]):
        raise RecoveryError("handoff native process identity is unavailable")
    pid = host.pid()
    for _ in range(64):
        if pid == expected["pid"]:
            return
        parent, command = host.parent(pid)
        if os.path.basename(command) == os.path.basename(image):
            raise RecoveryError("nested native client cannot hand off another launch")
        pid = int(parent)
        if pid <= 1:
            break
    raise RecoveryError("handoff caller is not a descendant of the bound native client")


def request_handoff(path, *, host=HOST, sessions=HerdrSession):
    try:
        _request_handoff(path, host=host, sessions=sessions)
    except FileNotFoundError:
        return  # Archived or expired obligations no longer authorize a handoff.


def _request_handoff(path, *, host=HOST, sessions=HerdrSession):
    with intent_lock(path, timeout=5, host=host):
        intent = read_intent(path)
        if intent["phase"] in Phase.TERMINAL:
            return
        require_client_ancestor(intent, host)
        sequence = intent["claim"]["handoff_seq"]
        if not intent["claim"]["claim_seq"] < sequence < intent["claim"]["release_seq"]:
            raise RecoveryError("handoff sequence was not reserved before acquisition")
        # Authorization must survive a failed first RPC and the hook's exit.
        intent["handoff_client"] = dict(intent["client"])
        intent.setdefault("handoff_requested_at_ns", host.wall_time_ns())
        atomic_write(path, intent)
        attempt_handoff(path, intent, host=host, sessions=sessions)


def attempt_handoff(path, intent, *, host=HOST, sessions=HerdrSession):
    """Retry an authorized request while holding its per-intent lock."""
    # Callers require the same live client incarnation. A reboot ends it;
    # ordinary observer restarts share this boot's monotonic clock with the hook.
    if intent.get("handoff_acknowledged"):
        return
    if host.monotonic() < intent.get("handoff_retry_after_monotonic", 0):
        return
    update_intent(path, intent, intent["phase"], reason_code="handoff_retry",
                  next_attempt_deadline=host.monotonic() + PENDING_RETRY_SECONDS,
                  deadline_clock="monotonic", host=host)
    try:
        expected = intent["handoff_client"]
        if expected != intent["client"] or host.start_identity(expected["pid"]) != expected["start_identity"]:
            update_intent(path, intent, intent["phase"], "pending: authorized handoff client changed or exited",
                          reason_code="handoff_client_changed", host=host)
            return
        session = sessions(intent)
        pane = session.locate_terminal()
        if pane is None:
            raise RecoveryError("handoff terminal identity is unavailable")
        sequence = intent["claim"]["handoff_seq"]
        if not intent["claim"]["claim_seq"] < sequence < intent["claim"]["release_seq"]:
            raise RecoveryError("handoff sequence was not reserved before acquisition")
        intent["terminal"]["pane_id"] = pane["pane_id"]
        intent["handoff_intended_at_ns"] = host.wall_time_ns()
        atomic_write(path, intent)
        state = session.release_with_readback(sequence)
        intent["handoff_acknowledged"] = True
        if state is None:
            update_intent(path, intent, Phase.SETTLED, "settled: terminal resource gone",
                          reason_code="terminal_gone", host=host)
            return
        # An ignored release also succeeds. Only the observer's later concrete
        # state read retires this obligation; the hook does not rename anything.
        update_intent(path, intent, intent["phase"], "pending: handoff awaiting published state",
                      reason_code="handoff_awaiting_state", host=host)
    except (OSError, RecoveryError) as error:
        record_connection_failure(path, intent, error, host=host, sessions=sessions)


def update_intent(intent_path, intent, phase, diagnostic=None, *, reason_code=None,
                  next_attempt_deadline=None, deadline_clock=None, host=HOST):
    """The lifecycle owner. Caller holds the inode-stable intent lock."""
    previous = intent["phase"]
    if phase not in Phase.ALLOWED.get(previous, ()):
        raise RecoveryError(f"invalid intent transition: {previous} -> {phase}")
    if previous in Phase.TERMINAL:
        if os.path.exists(intent_path):
            archive_terminal_intent(intent_path)
        return
    reason_code = reason_code or phase
    pending = {"reason_code": reason_code, "next_attempt_deadline": next_attempt_deadline,
               "deadline_clock": deadline_clock}
    if (phase == previous and intent.get("reason_code") == reason_code and
            intent.get("waiting") == pending and
            (diagnostic is None or diagnostic == intent.get("diagnostic"))):
        return
    intent["phase"] = phase
    intent["updated_at_ns"] = host.wall_time_ns()
    if phase == Phase.ACQUIRED and previous != phase:
        intent["acquired_at_ns"] = host.wall_time_ns()
    intent["reason_code"] = reason_code
    intent.pop("retry_after", None)
    intent.pop("handoff_retry_after_monotonic", None)
    if phase in Phase.TERMINAL:
        intent.pop("waiting", None)
    else:
        intent["waiting"] = pending
        if next_attempt_deadline is not None:
            key = "handoff_retry_after_monotonic" if deadline_clock == "monotonic" else "retry_after"
            intent[key] = next_attempt_deadline
    if diagnostic:
        intent["diagnostic"] = diagnostic
    atomic_write(intent_path, intent)
    if phase in Phase.TERMINAL:
        archive_terminal_intent(intent_path)


def waiting(path, intent, reason_code, diagnostic=None, *, retry=False, host=HOST):
    handoff_deadline = intent.get("handoff_retry_after_monotonic")
    if handoff_deadline is not None and not intent.get("handoff_acknowledged"):
        update_intent(path, intent, intent["phase"], diagnostic, reason_code=reason_code,
                      next_attempt_deadline=handoff_deadline, deadline_clock="monotonic", host=host)
        return
    update_intent(path, intent, intent["phase"], diagnostic, reason_code=reason_code,
                  next_attempt_deadline=host.wall_time() + PENDING_RETRY_SECONDS if retry else None,
                  deadline_clock="wall" if retry else None, host=host)


def record_connection_failure(path, intent, error, *, host=HOST, sessions=HerdrSession):
    if isinstance(error, ServerInstanceChanged):
        previous = intent["connection"]["server_identity"]
        try:
            old_start = host.start_identity(previous["pid"])
        except RecoveryError:
            old_start = previous["start_identity"]
        if old_start != previous["start_identity"]:
            # A new server may restore terminal records. Read it through a new
            # peer fence, but never mutate it using the previous server's claim.
            try:
                replacement = sessions(intent).replacement()
                pane = replacement.locate_terminal()
                if pane is None:
                    update_intent(path, intent, Phase.RETIRED, "retired: original terminal absent on replacement server",
                                  reason_code="replacement_terminal_absent", host=host)
                    return
                state = replacement.agent_state(pane)
                if state.get("error", {}).get("code") == "agent_not_found":
                    update_intent(path, intent, Phase.RETIRED, "retired: original claim absent on replacement server",
                                  reason_code="replacement_claim_absent", host=host)
                    return
                raise RecoveryError("replacement server retains a record; old ownership cannot be established")
            except (OSError, RecoveryError) as replacement_error:
                waiting(path, intent, "replacement_ownership_unknown", f"pending: {replacement_error}", host=host)
            return
    waiting(path, intent, "connection_unavailable", f"pending: {error}", host=host)


def observe_one(path, *, host=HOST, sessions=HerdrSession):
    try:
        with intent_lock(path, host=host):
            _observe_one_locked(path, host=host, sessions=sessions)
            return observation(read_intent(path))
    except IntentBusy:
        return Observation(None, "busy", "intent_busy")
    except FileNotFoundError:
        # Terminal receipts are immutable and need no newly created lock.
        try:
            intent = read_json(archived_intent_path(path))
            if intent["phase"] in Phase.TERMINAL:
                return observation(intent)
        except (OSError, ValueError, KeyError, TypeError):
            pass
        return Observation(None, "unavailable", "intent_unavailable")
    except (OSError, ValueError, KeyError, TypeError, RecoveryError):
        return Observation(None, "unavailable", "intent_unreadable")


def observation(intent):
    phase = intent["phase"]
    if phase not in Phase.ALLOWED:
        return Observation(None, "unavailable", "unsupported_phase")
    pending = intent.get("waiting", {})
    return Observation(phase, phase if phase in Phase.TERMINAL else "waiting",
                       intent.get("reason_code", phase),
                       pending.get("next_attempt_deadline"), pending.get("deadline_clock"))


def _observe_one_locked(path, *, host=HOST, sessions=HerdrSession):
    intent = read_intent(path)
    if intent["phase"] in Phase.TERMINAL:
        update_intent(path, intent, intent["phase"], host=host)
        return
    if intent["phase"] not in Phase.ACTIVE:
        raise RecoveryError("unsupported intent phase")
    if intent.get("identity_format") != IDENTITY_FORMAT:
        waiting(path, intent, "identity_format_unknown", "pending: unsupported process identity format", host=host)
        return
    pid = intent["client"]["pid"]
    expected_start = intent["client"]["start_identity"]
    try:
        actual_start = host.start_identity(pid)
    except RecoveryError as error:
        waiting(path, intent, "client_identity_unknown", f"pending: {error}", host=host)
        return
    client_alive = actual_start == expected_start
    session = sessions(intent)
    try:
        pane = session.locate_terminal()
    except (OSError, RecoveryError) as error:
        record_connection_failure(path, intent, error, host=host, sessions=sessions)
        return
    if pane is None:
        update_intent(path, intent, Phase.SETTLED, "settled: terminal resource gone", reason_code="terminal_gone", host=host)
        return
    if intent["terminal"]["pane_id"] != pane["pane_id"]:
        intent["terminal"]["pane_id"] = pane["pane_id"]
        atomic_write(path, intent)
    try:
        acquisition = session.agent_state(pane)
    except (OSError, RecoveryError) as error:
        record_connection_failure(path, intent, error, host=host, sessions=sessions)
        return
    if intent["phase"] == Phase.ACQUIRED and "error" not in acquisition:
        state = acquisition["result"]["agent"].get("agent_status")
        # This launch declared only unknown. A newer same-source report or a
        # client report can publish a concrete state; neither belongs to us.
        if acquisition["result"]["agent"].get("agent") and state in {"working", "idle", "done", "blocked"}:
            update_intent(path, intent, Phase.RETIRED, "retired: concrete successor state observed",
                          reason_code="concrete_successor", host=host)
            return
    if client_alive:
        if intent.get("handoff_requested_at_ns") and intent.get("handoff_client") == intent["client"]:
            attempt_handoff(path, intent, host=host, sessions=sessions)
        else:
            update_intent(path, intent, intent["phase"], reason_code="client_alive", host=host)
        return
    if intent.get("handoff_retry_after_monotonic") is not None:
        # A handoff deadline belongs only to the live authorized incarnation.
        update_intent(path, intent, intent["phase"], reason_code="client_exited", host=host)
    if intent["phase"] == Phase.INTENT:
        if acquisition.get("error", {}).get("code") == "agent_not_found":
            # The acquisition request may still arrive. Absence now cannot
            # settle an unacknowledged operation on a live server and pane.
            waiting(path, intent, "acquisition_unknown", "pending: acquisition outcome unknown", host=host)
            return
        if "error" in acquisition:
            waiting(path, intent, "acquisition_lookup_failed", f"pending: acquisition lookup failed: {acquisition['error']}", host=host)
            return
    if host.wall_time() < intent.get("retry_after", 0):
        return
    try:
        state = session.release_with_readback(intent["claim"]["release_seq"])
    except (OSError, RecoveryError) as error:
        record_connection_failure(path, intent, error, host=host, sessions=sessions)
        return
    if state is None:
        update_intent(path, intent, Phase.SETTLED, "settled: terminal resource gone", reason_code="terminal_gone", host=host)
        return
    if "error" not in state:
        # agent.get exposes no claim source/sequence. Unknown may belong to a
        # newer launch; successful RPC status cannot prove that distinction.
        waiting(path, intent, "release_still_published", "pending: release acknowledged but claim still published", retry=True, host=host)
        return
    if state["error"].get("code") != "agent_not_found":
        waiting(path, intent, "release_readback_failed", f"pending: state check failed: {state['error']}", host=host)
        return
    update_intent(path, intent, Phase.SETTLED, "settled: exact owned release observed", reason_code="release_observed", host=host)


def observer(root, job_label=None, engine_factory=RecoveryEngine):
    engine = engine_factory(root)
    store = engine.store
    intent_dir = store.intents
    os.makedirs(intent_dir, exist_ok=True)
    host = engine.host
    identity = host.start_identity(host.pid())
    receipt = {"pid": host.pid(), "start_identity": identity, "identity_format": IDENTITY_FORMAT,
               "started_at_ns": host.wall_time_ns(), "job_label": job_label,
               "state_root": store.root,
               "python_version": list(sys.version_info[:3]), "engine_digest": engine_digest()}
    atomic_write(store.receipt, receipt)
    atomic_write(store.ready, receipt)
    next_prune = 0
    while True:
        try:
            paths = active_intent_paths(intent_dir)
        except FileNotFoundError:
            print("recovery pending: intent directory is unavailable", file=sys.stderr, flush=True)
            host.sleep(PENDING_RETRY_SECONDS)
            continue
        for path in paths:
            try:
                result = engine.observe_one(os.path.basename(path)[:-5])
                if result.outcome == "unavailable":
                    print(f"observer unavailable {os.path.basename(path)}: {result.reason_code}",
                          file=sys.stderr, flush=True)
            except (OSError, ValueError, KeyError, RecoveryError) as error:
                print(f"observer pending {os.path.basename(path)}: {error}", file=sys.stderr, flush=True)
        if host.monotonic() >= next_prune:
            try:
                prune_intent_archive(intent_dir, now=host.wall_time())
            except OSError as error:
                print(f"archive maintenance pending: {error}", file=sys.stderr, flush=True)
            next_prune = host.monotonic() + ARCHIVE_PRUNE_SECONDS
        host.sleep(POLL_SECONDS)


def engine_digest():
    with open(__file__, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def launchd_job(domain, label):
    result = subprocess.run(["launchctl", "print", f"{domain}/{label}"],
                            text=True, capture_output=True, check=False, timeout=10)
    if result.returncode:
        if any(text in result.stderr for text in ("Could not find service", "No such process")):
            return None
        raise RecoveryError(f"launchd lookup failed: {result.stderr.strip()}")
    pid = re.search(r"^\s*pid = (\d+)\s*$", result.stdout, re.MULTILINE)
    path = re.search(r"^\s*path = (.+)$", result.stdout, re.MULTILINE)
    return {"pid": int(pid.group(1)) if pid else None,
            "path": os.path.realpath(path.group(1).strip()) if path else None}


def owner_receipt(root, label, job, host=HOST):
    if not job or job["pid"] is None:
        return None
    try:
        store = RecoveryRoot(root)
        receipt = read_json(store.ready)
        if (receipt.get("job_label") == label and receipt.get("pid") == job["pid"] and
                receipt.get("state_root") == store.root and
                receipt.get("engine_digest") == engine_digest() and
                tuple(receipt.get("python_version", [])) >= (3, 10) and
                receipt.get("start_identity") is not None and receipt.get("identity_format") == IDENTITY_FORMAT and
                host.start_identity(job["pid"]) == receipt["start_identity"]):
            return receipt
    except (OSError, ValueError, TypeError, RecoveryError):
        pass
    return None


def ensure_owner(root, label, plist, host=HOST):
    """Start the installed owner and accept readiness only from its live PID."""
    if sys.platform != "darwin":
        raise RecoveryError("automatic claim recovery is unsupported on this host")
    if not os.path.isfile(plist):
        raise RecoveryError("recovery launchd plist is unavailable")
    with open(plist, "rb") as handle:
        configuration = plistlib.load(handle)
    argv = configuration.get("ProgramArguments", [])
    def configured_argument(flag):
        try:
            return argv[argv.index(flag) + 1]
        except (ValueError, IndexError):
            return None
    def configured_path(flag):
        value = configured_argument(flag)
        return os.path.realpath(value) if isinstance(value, str) else None
    store = RecoveryRoot(root)
    if (configuration.get("Label") != label or
            configuration.get("RunAtLoad") is not True or
            not isinstance(configuration.get("KeepAlive"), dict) or
            configuration["KeepAlive"].get("SuccessfulExit") is not False or
            configured_path("--observe") != store.root or
            configured_argument("--job-label") != label or
            len(argv) < 2 or os.path.realpath(argv[1]) != os.path.realpath(sys.argv[0]) or
            not os.access(argv[0], os.X_OK)):
        raise RecoveryError("recovery job does not match the requested engine, state root and restart policy")
    os.makedirs(store.intents, exist_ok=True)
    domain = f"gui/{os.getuid()}"
    with intent_lock(store.owner_lock, timeout=15, create=True, host=host):
        job = launchd_job(domain, label)
        if job and job["path"] != os.path.realpath(plist):
            raise RecoveryError("recovery label is owned by another launchd configuration")
        ready = owner_receipt(root, label, job, host)
        if ready:
            return ready
        if job:
            result = subprocess.run(["launchctl", "bootout", f"{domain}/{label}"],
                                    text=True, capture_output=True, check=False, timeout=10)
            if result.returncode and launchd_job(domain, label) is not None:
                raise RecoveryError(f"stale owner could not stop: {result.stderr.strip()}")
        try:
            os.unlink(store.ready)
        except FileNotFoundError:
            pass
        result = subprocess.run(["launchctl", "bootstrap", domain, plist], text=True,
                                capture_output=True, check=False, timeout=10)
        if result.returncode:
            raise RecoveryError(f"launchd bootstrap failed: {result.stderr.strip()}")
        deadline = host.monotonic() + 8
        while host.monotonic() < deadline:
            job = launchd_job(domain, label)
            if job and job["path"] != os.path.realpath(plist):
                raise RecoveryError("launchd owner configuration changed during startup")
            ready = owner_receipt(root, label, job, host)
            if ready:
                return ready
            host.sleep(POLL_SECONDS)
        raise RecoveryError("launchd recovery owner did not become ready")


def launcher_identity(launcher_pid, host):
    observed_start = host.start_identity(launcher_pid)
    if observed_start is None:
        raise RecoveryError("launcher process identity is unavailable")
    parent = host.parent_pid()
    for _ in range(64):
        if parent == launcher_pid:
            break
        if parent <= 1:
            raise RecoveryError("admission caller is not a descendant of the launcher")
        parent, _ = host.parent(parent)
    else:
        raise RecoveryError("launcher ancestry exceeds the supported depth")
    if host.start_identity(launcher_pid) != observed_start:
        raise RecoveryError("launcher incarnation changed during admission")
    return observed_start


def prepare_intent(intent_dir, agent, source, launcher_pid, *,
                   socket_path, pane_id, host=HOST, sessions=HerdrSession,
                   scope, launcher_start):
    """Persist the fenced launch obligation before acquisition."""
    observed_start = launcher_identity(launcher_pid, host)
    if observed_start != launcher_start:
        raise RecoveryError("launcher incarnation changed during admission")
    if not pane_id or not socket_path:
        raise RecoveryError("current Herdr pane or socket is unavailable")
    connection = scope["connection"]
    response = sessions({"connection": connection}).request("pane.get", {"pane_id": pane_id})
    if "error" in response:
        raise RecoveryError(f"launch pane lookup failed: {response['error']}")
    terminal = response["result"]["pane"]
    if terminal["terminal_id"] != scope["terminal"]["terminal_id"]:
        raise RecoveryError("launch terminal changed during admission")
    sequence = reserve_sequence(os.path.join(os.path.dirname(intent_dir), "sequences"), source, host)
    intent = {
        "launch_id": f"launch-{agent}-{launcher_pid}-{host.wall_time_ns()}",
        "identity_format": IDENTITY_FORMAT,
        "phase": Phase.INTENT,
        "reason_code": "acquisition_unknown",
        "waiting": {"reason_code": "acquisition_unknown", "next_attempt_deadline": None,
                    "deadline_clock": None},
        "connection": connection,
        "terminal": {"pane_id": terminal["pane_id"], "terminal_id": terminal["terminal_id"]},
        "agent_kind": agent,
        "claim": {"source": source, "claim_seq": sequence,
                  "handoff_seq": sequence + 1, "release_seq": sequence + 2},
        "client": {"pid": launcher_pid, "start_identity": observed_start},
        "created_at_ns": host.wall_time_ns(),
    }
    return write_intent(intent_dir, intent), intent


def claim_intent(intent_dir, agent, source, alias, launcher_pid, *,
                 socket_path, pane_id, host=HOST, sessions=HerdrSession,
                 scope, launcher_start):
    """Create and acknowledge one fenced claim, or retire its own failed try."""
    os.makedirs(intent_dir, exist_ok=True)
    path, intent = prepare_intent(intent_dir, agent, source, launcher_pid,
                                  socket_path=socket_path, pane_id=pane_id, host=host, sessions=sessions,
                                  scope=scope, launcher_start=launcher_start)
    handle = os.path.basename(path)[:-5]
    try:
        with intent_lock(path, timeout=5, host=host):
            intent = read_json(path)
            if intent["phase"] != Phase.INTENT or host.start_identity(launcher_pid) != intent["client"]["start_identity"]:
                raise RecoveryError("launch obligation is no longer eligible for acquisition")
            session = sessions(intent)
            response = session.request("pane.report_agent", {
                "pane_id": intent["terminal"]["pane_id"], "source": source,
                "agent": agent, "state": "unknown", "seq": intent["claim"]["claim_seq"],
            })
            if "error" in response:
                raise RecoveryError(f"claim rejected: {response['error']}")
            response = session.request("agent.rename", {
                "target": intent["terminal"]["pane_id"], "name": alias,
            })
            if "error" in response:
                state = session.release_with_readback(intent["claim"]["release_seq"])
                if state is not None and state.get("error", {}).get("code") != "agent_not_found":
                    raise RecoveryError("rejected alias cleanup was not observed")
                update_intent(path, intent, Phase.SETTLED, "settled: alias acquisition rejected",
                              reason_code="alias_rejected", host=host)
                code = response["error"].get("code")
                # Herdr 0.9.3 clears agent_session after exit but still ignores
                # declarations in used panes. Only confirmed rollback makes
                # this rename failure safe for the deferred-rename route.
                return {"claimed": False, "error": response["error"], "intent": path, "intent_id": handle,
                        "retry": code == "agent_name_taken",
                        "undeclarable": code == "agent_not_found", "pending": False}
            visible = session.request("agent.get", {"target": intent["terminal"]["pane_id"]})
            record = visible.get("result", {}).get("agent", {})
            if ("error" in visible or record.get("name") != alias or record.get("agent") != agent or
                    record.get("terminal_id") != intent["terminal"]["terminal_id"] or
                    record.get("agent_status") != "unknown"):
                raise RecoveryError("claim readback did not match this launch")
            update_intent(path, intent, Phase.ACQUIRED, reason_code="client_alive", host=host)
            return {"claimed": True, "intent": path, "intent_id": handle, "claim_seq": intent["claim"]["claim_seq"],
                    "handoff_seq": intent["claim"]["handoff_seq"], "release_seq": intent["claim"]["release_seq"]}
    except (OSError, ValueError, KeyError, RecoveryError) as error:
        return {"claimed": False, "intent": path, "intent_id": handle, "error": str(error), "retry": False, "pending": True}


def main(engine_factory=RecoveryEngine):
    if sys.platform == "darwin" and sys.version_info < (3, 10):
        raise RecoveryError("claim recovery requires Python 3.10 or later on macOS")
    parser = argparse.ArgumentParser()
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--admit", metavar="ROOT")
    parser.add_argument("--socket-path")
    parser.add_argument("--pane-id")
    modes.add_argument("--observe", metavar="ROOT")
    parser.add_argument("--job-label")
    modes.add_argument("--handoff", metavar="ROOT")
    modes.add_argument("--bind-exec", metavar="ROOT")
    parser.add_argument("--intent")
    parser.add_argument("--native-leaf")
    parser.add_argument("--agent")
    parser.add_argument("--launcher-pid", type=int)
    parser.add_argument("bridge_args", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    if arguments.admit:
        if not all((arguments.agent, arguments.launcher_pid)):
            parser.error("admission requires --agent and --launcher-pid")
        result = engine_factory(arguments.admit).admit(
            socket_path=arguments.socket_path, pane_id=arguments.pane_id,
            agent=arguments.agent, launcher_pid=arguments.launcher_pid)
        print(result.tsv())
        return
    if arguments.handoff:
        if not arguments.intent:
            parser.error("handoff requires --intent")
        result = engine_factory(arguments.handoff).handoff(arguments.intent)
        print(json.dumps(result._asdict()))
        return
    if arguments.bind_exec is not None:
        if not arguments.native_leaf or not arguments.intent:
            parser.error("bind-exec requires --intent and --native-leaf")
        args = arguments.bridge_args
        if args[:1] == ["--"]:
            args = args[1:]
        # cci probes its configured bridge with --version even for MCP mode.
        # That short-lived utility is not the native interactive client.
        if args == ["--version"]:
            os.execv(arguments.native_leaf, [arguments.native_leaf, *args])
        try:
            if not arguments.bind_exec:
                raise RecoveryError("claim binding root is unavailable")
            engine = engine_factory(arguments.bind_exec)
            bound = engine.bind(arguments.intent, os.environ.get("AGENT_INTERCOM_CLAUDE_COMMAND"))
        except (OSError, ValueError, KeyError, RecoveryError) as error:
            print(f"claim binding unavailable: {error}", file=sys.stderr)
            bound = False
        os.environ["HERDR_AGENT_INTERCOM_NATIVE_ONLY"] = "0" if bound else "1"
        if not bound:
            print("claim binding unavailable; starting native Claude without enrollment", file=sys.stderr, flush=True)
        os.execv(arguments.native_leaf, [arguments.native_leaf, *args])
    if not arguments.observe:
        parser.error("observe requires a nonempty root")
    observer(arguments.observe, arguments.job_label, engine_factory)


def cli():
    try:
        main()
    except (OSError, ValueError, KeyError, RecoveryError) as error:
        print(f"herdr-agent-intercom recovery: {error}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    cli()
