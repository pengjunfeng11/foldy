#!/usr/bin/env python3
"""Offline guardian observations: no messages, transcript reads, or power changes."""
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
from unittest.mock import patch

sys.dont_write_bytecode = True
import bendy_hooks as hooks


def main():
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        home = root / "Codex"
        home.mkdir()
        now = time.time()
        old_turn = "01900000-0000-7000-8000-000000000001"
        new_turn = "01900000-0001-7000-8000-000000000001"
        segment = "00000000-0000-0000-0000-000000000001"
        rollout = home / ("rollout-" + segment + ".jsonl")
        rollout.write_bytes(b"this body must never be read")

        def observe(ids=()):
            return hooks.guardian_status(root, home, now, ids)

        assert observe()["reason"] == "missing_catalog"
        with sqlite3.connect(home / "state_5.sqlite") as db:
            db.execute("CREATE TABLE threads(id,rollout_path,name,title,updated_at,cwd,source,agent_role,archived)")
        assert observe()["reason"] == "metadata_unavailable" and not observe()["trustworthy"]
        with sqlite3.connect(home / "thread_history_1.sqlite") as db:
            db.executescript("CREATE TABLE thread_turns(thread_id,turn_id,rollout_ordinal,status,started_at,completed_at);"
                             "CREATE TABLE thread_history_projection_state(thread_id,next_rollout_byte_offset);")
        assert observe()["trustworthy"] and observe()["active_count"] == 0  # Empty observed catalog is clear.
        with sqlite3.connect(home / "state_5.sqlite") as db:
            db.execute("INSERT INTO threads VALUES(?,?,?,?,?,?,?,?,?)",
                       ("task", str(rollout), "Task name", "fallback", now, "/project", "vscode", None, 0))
        with sqlite3.connect(home / "thread_history_1.sqlite") as db:
            db.execute("INSERT INTO thread_turns VALUES(?,?,?,?,?,?)", (segment, new_turn, 2, "inProgress", now - 20, None))
            db.execute("INSERT INTO thread_history_projection_state VALUES(?,?)", (segment, rollout.stat().st_size))

        def event(status, turn=new_turn, updated=now - 1):
            (root / "state.json").write_text(json.dumps({"tasks": {"task": {
                "status": status, "turn_id": turn, "updated_at": updated, "project": "Project"}}}))

        def metadata(status, turn=new_turn, started=now - 20, completed=None):
            with sqlite3.connect(home / "thread_history_1.sqlite") as db:
                db.execute("UPDATE thread_turns SET status=?,turn_id=?,started_at=?,completed_at=?",
                           (status, turn, started, completed))

        status = observe()
        assert status["active_count"] == 1 and status["running"][0]["source"] == "turn_metadata"
        event("attention")
        status = observe()
        assert status["active_count"] == 0 and status["waiting_count"] == 1 and status["trustworthy"]
        event("running")
        assert observe()["active_count"] == 1
        metadata("completed", completed=int(now - 1))  # Whole-second completion beats same-turn fractional Hook.
        status = observe()
        assert status["active_count"] == 0 and status["tasks"][0]["status"] == "idle"
        metadata("completed", turn=old_turn, completed=now + 1)
        assert observe()["active_count"] == 1  # Late old completion cannot stop the new turn.
        event("unknown")
        assert observe()["unknown_count"] == 1  # An unknown newer turn cannot be called complete using the old turn.
        event("idle", turn=old_turn, updated=now + 1)
        metadata("inProgress")
        assert observe()["active_count"] == 1  # Nor can a delayed old Stop.
        metadata("completed", completed=now - 1)
        assert observe()["tasks"][0]["turn_id"] == new_turn and observe()["active_count"] == 0

        (root / "state.json").unlink()
        metadata("inProgress", started=now - hooks.STALE_SECONDS - 1)
        status = observe()
        assert status["active_count"] == 0 and status["unknown_count"] == 1 and not status["trustworthy"]
        with sqlite3.connect(home / "state_5.sqlite") as db:
            db.execute("UPDATE threads SET updated_at=?", (now - 86400 * 30,))
        assert observe()["trustworthy"] and not observe()["tasks"]  # Unrelated months-old residue is out of scope.
        assert observe(["task"])["unknown_count"] == 1  # Tracked jobs never silently disappear after a day.
        metadata("completed", completed=now - 86400)
        assert observe(["task"])["tasks"][0]["status"] == "idle"
        assert observe(["not-in-catalog"])["unknown_count"] == 1

        with sqlite3.connect(home / "state_5.sqlite") as db:
            db.execute("UPDATE threads SET updated_at=?", (now,))
        metadata("inProgress")
        rollout.write_bytes(b"projection is lagging now")
        status = observe()
        assert status["unknown_count"] == 1 and not status["trustworthy"] and status["active_count"] == 0
        with sqlite3.connect(home / "state_5.sqlite") as db:
            db.execute("UPDATE threads SET updated_at=?", (now - 86399,))
        assert observe()["unknown_count"] == 1  # Guardian scope crosses midnight; notification's today filter does not apply.
        event("running")
        assert observe()["active_count"] == 1  # A fresh Hook remains useful while metadata is catching up.
        event("attention")
        assert observe()["waiting_count"] == 1 and observe()["active_count"] == 0

        # The read path must not use app-server, send messages, read transcripts or
        # acquire the writer lock. Its existing state/config bytes stay identical.
        before = (root / "state.json").read_bytes()
        with patch.object(hooks, "AppServer", side_effect=AssertionError("app-server")), \
             patch.object(hooks, "send_cli", side_effect=AssertionError("send")), \
             patch.object(hooks, "save", side_effect=AssertionError("write")), \
             patch.object(hooks, "lock", side_effect=AssertionError("lock")):
            assert observe()["waiting_count"] == 1
        assert (root / "state.json").read_bytes() == before
        assert not (root / "config.json").exists()
        with patch.object(hooks.time, "monotonic", side_effect=[1, 2, 3]):
            assert observe()["reason"] == "timeout"
        assert observe(["/invalid"])["reason"] == "invalid_task_ids"
        with sqlite3.connect(home / "thread_history_1.sqlite") as db:
            db.execute("DROP TABLE thread_turns")
        status = observe()
        assert not status["trustworthy"] and status["active_count"] == 0
    print("PASS: guardian running/completed/waiting, turn ordering, stale/missing/lagging metadata, tracked overnight IDs, bounded read-only failure")


if __name__ == "__main__":
    main()
