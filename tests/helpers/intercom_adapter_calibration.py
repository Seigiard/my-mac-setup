#!/usr/bin/env python3
"""One opt-in run comparing fake wire evidence with an owned real Herdr."""

import json
import os
import shutil
import subprocess
import sys

from intercom_recovery_adapters import FakeHerdr, recovery
from intercom_claim_ownership_probe import OwnedHerdr, create_pane


def checked(response):
    if "error" in response:
        raise AssertionError(response)
    return response


def scenarios(factory, socket_path, first, second, move, replace):
    # These are adapter connection/terminal arguments, never persisted intents.
    connection = factory.connect(socket_path)
    scope = {"connection": connection, "terminal": first, "agent_kind": "claude",
             "claim": {"source": "mms393-calibration"}}
    session = factory(scope)
    request = session.request
    first_id, second_id = first["pane_id"], second["pane_id"]
    source = "mms393-calibration"
    report = {"pane_id": first_id, "source": source, "agent": "claude", "state": "unknown", "seq": 100}
    checked(request("pane.report_agent", report))
    checked(request("agent.rename", {"target": first_id, "name": "mms393-calibration-owner"}))
    agent = checked(request("agent.get", {"target": first_id}))["result"]["agent"]
    results = {"unknown_record": agent["agent_status"],
               "ownership_fields_absent": all(key not in agent for key in ("source", "seq"))}
    checked(request("pane.report_agent", {**report, "pane_id": second_id}))
    collision = request("agent.rename", {"target": second_id, "name": "mms393-calibration-owner"})
    results["collision"] = collision.get("error", {}).get("code")
    other = factory({**scope, "terminal": second})
    results["collision_rollback"] = other.release_with_readback(102).get("error", {}).get("code")
    checked(request("pane.report_agent", {**report, "seq": 110}))
    results["unknown_successor_after_old_release"] = session.release_with_readback(102)["result"]["agent"]["agent_status"]
    checked(request("pane.report_agent", {**report, "seq": 120, "state": "working"}))
    results["concrete_successor_after_old_release"] = session.release_with_readback(112)["result"]["agent"]["agent_status"]
    checked(request("pane.report_agent", {**report, "source": "mms393-native", "seq": 1, "state": "working"}))
    results["foreign_successor_after_old_release"] = session.release_with_readback(122)["result"]["agent"]["agent_status"]
    checked(request("pane.release_agent", {"pane_id": first_id, "source": "mms393-native", "agent": "claude", "seq": 2}))
    checked(request("pane.report_agent", {**report, "seq": 130}))
    moved = move(first_id)
    located = session.locate_terminal()
    results["stable_terminal_relocation"] = located["terminal_id"] == first["terminal_id"] and located["pane_id"] == moved
    results["release_readback"] = session.release_with_readback(132).get("error", {}).get("code")
    replace()
    # Make pathname metadata agree with the replacement while retaining the old
    # peer identity. An inode/path-only fence would now permit this mutation.
    connection["socket_identity"] = factory.connect(socket_path).get("socket_identity")
    try:
        # Deliberately valid mutation: only the connected-descriptor fence may reject it.
        request("pane.report_agent", {**report, "seq": 140})
    except recovery.ServerInstanceChanged:
        results["replacement_descriptor_fenced"] = True
    else:
        raise AssertionError("stale adapter mutated replacement server")
    results["replacement_read_allowed"] = "result" in session.replacement().request("session.snapshot", {})
    return results


def main():
    if os.environ.get("MMS_LIVE_HERDR_CALIBRATION") != "1" or not shutil.which("herdr"):
        print("SKIPPED/UNVERIFIED: MMS_LIVE_HERDR_CALIBRATION=1 and installed Herdr required")
        return 3
    if os.environ.get("HERDR_ENV") != "1":
        print("SKIPPED/UNVERIFIED: requires an owned Herdr pane")
        return 3
    version = subprocess.run(["herdr", "--version"], text=True, capture_output=True, check=True).stdout.strip()
    fake = FakeHerdr()
    def fake_move(pane):
        fake.move(pane, "w2:p1")
        return "w2:p1"
    modeled = scenarios(fake, "fake.sock", dict(fake.panes["w1:p1"]), dict(fake.panes["w1:p2"]), fake_move, fake.replace)
    owner = OwnedHerdr()
    try:
        root = owner.start()
        first, second = create_pane(owner, root), create_pane(owner, root)
        def live_move(pane):
            response = owner.run("pane", "move", pane, "--new-workspace", "--no-focus")
            return json.loads(response.stdout)["result"]["move_result"]["pane"]["pane_id"]
        def live_replace():
            owner.run("server", "stop")
            owner.client.wait(timeout=5)
            owner.start()
        observed = scenarios(recovery.HerdrSession, owner.socket_path, first, second, live_move, live_replace)
        if observed != modeled:
            raise AssertionError({"fake": modeled, "real": observed})
        print(json.dumps({"version": version, "scenarios": observed, "verdict": "PASS"}, sort_keys=True), flush=True)
    finally:
        owner.close()
        print("CALIBRATION_RESOURCES_CLOSED", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
