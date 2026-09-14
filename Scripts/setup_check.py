#!/usr/bin/env python3
"""Offline onboarding check: no login, network, user config, or messages."""
import copy
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

sys.dont_write_bytecode = True
import foldy_setup as setup
import bendy_hooks as hooks


def turn_metadata_check(directory):
    home = directory / "Codex Metadata"
    home.mkdir()
    segment = "00000000-0000-0000-0000-000000000001"
    rollout = home / ("rollout-" + segment + ".jsonl")
    rollout.write_bytes(b"metadata-only fixture")
    now = hooks.time.time()
    old_turn, new_turn = "01900000-0000-7000-8000-000000000001", "01900000-0001-7000-8000-000000000001"
    with sqlite3.connect(home / "thread_history_1.sqlite") as db:
        db.executescript("CREATE TABLE thread_turns(thread_id,turn_id,rollout_ordinal,status,started_at,completed_at);"
                         "CREATE TABLE thread_history_projection_state(thread_id,next_rollout_byte_offset);")
        db.executemany("INSERT INTO thread_turns VALUES(?,?,?,?,?,?)", [
            (segment, old_turn, 1, "completed", now - 200, now - 100),
            (segment, new_turn, 2, "inProgress", now - 20, None)])
        db.execute("INSERT INTO thread_history_projection_state VALUES(?,?)", (segment, rollout.stat().st_size))
    with sqlite3.connect(home / "state_5.sqlite") as db:
        db.execute("CREATE TABLE threads(id,rollout_path)")
        db.execute("INSERT INTO threads VALUES(?,?)", ("task", str(rollout)))
    thread = {"id": "task", "session_id": "task", "title": "Fixture", "project": "Fixture", "updated_at": now}
    data = {"snapshot": {"threads": [thread]}}
    assert hooks.task_rows(data, now)[0]["status"] == "unknown"
    fresh = hooks.latest_turn_states([thread], home)
    data["snapshot"]["turn_states"] = fresh
    assert hooks.task_rows(data, now)[0]["status"] == "running"
    assert hooks.task_rows(data, now)[0]["status_source"] == "turn_metadata"
    data["tasks"] = {"task": {"status": "unknown", "turn_id": new_turn, "updated_at": now}}
    assert hooks.task_rows(data, now)[0]["status"] == "running"  # SessionStart alone has no runtime status.
    data["tasks"] = {"task": {"status": "idle", "turn_id": old_turn, "updated_at": now}}
    assert hooks.task_rows(data, now)[0]["status"] == "running"  # A delayed old Stop cannot stop the newer turn.
    data["snapshot"]["turn_states"] = {"task": dict(fresh["task"], turn_id=old_turn)}
    data["tasks"]["task"] = {"status": "idle", "turn_id": new_turn, "updated_at": now}
    assert hooks.task_rows(data, now)[0]["status"] == "idle"  # Old recorded running cannot replace a newer Stop.
    data["snapshot"]["turn_states"] = {"task": dict(fresh["task"], turn_id="invalid-turn")}
    assert hooks.task_rows(data, now)[0]["status"] == "idle"
    data["snapshot"]["turn_states"] = fresh
    data["tasks"]["task"] = {"status": "attention", "turn_id": new_turn, "updated_at": now}
    assert hooks.task_rows(data, now)[0]["status"] == "attention"  # Fresh hooks remain authoritative.

    cache_root = directory / "Cached Snapshot"
    cache_root.mkdir()
    hooks.save(cache_root / "state.json", {"snapshot": {"threads": [thread], "fetched_at": now,
                                                      "quota": {"untouched": True}}})
    with patch.object(hooks, "latest_turn_states", return_value=fresh) as reader, \
         patch.object(hooks, "AppServer", side_effect=AssertionError("Do not bypass the quota cache")):
        conf = {"codex_home": str(home)}
        assert hooks.refresh(cache_root, conf, now + 1)["turn_states"]["task"]["status"] == "running"
        reader.assert_called_with([thread], str(home))
        reader.return_value = {"task": dict(fresh["task"], status="idle", updated_at=now + 2)}
        assert hooks.refresh(cache_root, conf, now + 2)["turn_states"]["task"]["status"] == "idle"
        assert reader.call_count == 2
    assert hooks.load(cache_root / "state.json", {})["snapshot"]["quota"] == {"untouched": True}
    rollout.write_bytes(b"new data not yet projected")
    assert hooks.latest_turn_states([thread], home) == {}  # Never open or parse the rollout body.
    assert hooks.latest_turn_states([thread], directory / "Unsupported Version") == {}


def notification_check(directory, connected, identity):
    auth = copy.deepcopy(identity)
    sent = []

    def cli(command, **kwargs):
        assert kwargs["env"]["LARKSUITE_CLI_CONFIG_DIR"] == connected["lark_config_dir"]
        if command[1:3] == ["auth", "status"]:
            assert command[3:] == ["--json", "--verify"]
            return SimpleNamespace(returncode=0, stdout=json.dumps(auth))
        assert command[1:3] == ["im", "+messages-send"]
        assert command[command.index("--user-id") + 1] == connected["account_open_id"]
        sent.append(command)
        return SimpleNamespace(returncode=0, stdout=json.dumps({"ok": True, "data": {"message_id": "om_offline"}}))

    item = {"connection_id": connected["connection_id"], "as": "bot",
            "recipient": connected["recipient_open_id"], "text": "Offline fixture"}
    with patch.object(hooks.subprocess, "run", cli):
        auth["appId"] = "cli_wrongapp"
        assert not hooks.send_cli(connected, item, "offline-app")["ok"] and not sent
        auth["appId"] = connected["app_id"]
        auth["identities"]["user"]["openId"] = "ou_wrongaccount"
        assert not hooks.send_cli(connected, item, "offline-user")["ok"] and not sent
        auth["identities"]["user"]["openId"] = connected["account_open_id"]
        for name in ("user", "bot"):
            auth["identities"][name]["verified"] = False
            assert not hooks.send_cli(connected, item, "offline-unverified")["ok"] and not sent
            auth["identities"][name]["verified"] = True
        assert not hooks.send_cli(connected, dict(item, recipient="ou_wrongrecipient"), "offline-recipient")["ok"] and not sent
        assert not hooks.send_cli(connected, dict(item, connection_id="old"), "offline-connection")["ok"] and not sent
        assert hooks.send_cli(connected, item, "offline-ok")["ok"] and len(sent) == 1
    for conf in (connected, dict(connected, connection_id=None)):
        for code in (126, 127):
            with patch.object(hooks.subprocess, "run", return_value=SimpleNamespace(
                    returncode=code, stdout="", stderr="env: node: No such file or directory")):
                failed = hooks.send_cli(conf, item, "offline-startup")
                assert not failed["ok"] and failed["uncertain"] is False and "未发送" in failed["error"]
        for error in (FileNotFoundError(), PermissionError()):
            with patch.object(hooks.subprocess, "run", side_effect=error):
                failed = hooks.send_cli(conf, item, "offline-missing-cli")
                assert not failed["ok"] and failed["uncertain"] is False and "未发送" in failed["error"]

    queue_root = directory / "Queue"
    queue_root.mkdir()
    hooks.save(queue_root / "config.json", connected)
    hooks.enqueue(queue_root, "never-attempted")
    hooks.enqueue(queue_root, "already-attempted")
    with hooks.state(queue_root) as data:
        data["outbox"]["already-attempted"]["first_attempt_at"] = hooks.time.time()
        data["outbox"]["legacy-pending"] = {"created_at": hooks.time.time(), "status": "pending"}
    replacement = dict(connected, connection_id="new-connection", account_open_id="ou_new", recipient_open_id="ou_new")
    hooks.save(queue_root / "config.json", replacement)
    attempted = []

    def success(conf, frozen, key):
        attempted.append((key, frozen))
        return {"ok": True, "message_id": "om_offline"}

    for key in ("never-attempted", "already-attempted", "legacy-pending"):
        assert not hooks.deliver(queue_root, key, replacement, success)["ok"]
    assert not attempted
    hooks.enqueue(queue_root, "fresh-connection")
    assert hooks.deliver(queue_root, "fresh-connection", replacement, success)["ok"]
    assert [key for key, _ in attempted] == ["fresh-connection"]
    assert set(hooks.pending(queue_root)) == {"never-attempted", "already-attempted", "legacy-pending"}
    hooks.enqueue(queue_root, "fresh-wake")
    before_wake = hooks.load(queue_root / "state.json", {})["outbox"]
    with patch.object(hooks, "refresh", return_value={}), patch.object(hooks, "deliver", return_value={"ok": True}) as delivery:
        assert hooks.send_pending(queue_root, replacement)["ok"]
        assert [call.args[1] for call in delivery.call_args_list] == ["fresh-wake"]
    assert hooks.load(queue_root / "state.json", {})["outbox"] == before_wake

    retry_root = directory / "Retry Queue"
    retry_root.mkdir()
    hooks.save(retry_root / "config.json", connected)
    now = hooks.time.time()
    for key in ("old-uncertain-1", "old-uncertain-2", "recent-pending"):
        hooks.enqueue(retry_root, key)
    with hooks.state(retry_root) as data:
        for key in ("old-uncertain-1", "old-uncertain-2"):
            data["outbox"][key].update(uncertain=True, created_at=now - 7200, first_attempt_at=now - 3601)
        before = copy.deepcopy(data["outbox"])
    with patch.object(hooks, "refresh", return_value={}), patch.object(hooks, "deliver", return_value={"ok": True}) as delivery:
        assert hooks.send_pending(retry_root, connected)["ok"]
        assert [call.args[1] for call in delivery.call_args_list] == ["recent-pending"]
    assert hooks.load(retry_root / "state.json", {})["outbox"] == before
    assert len(hooks.pending(retry_root)) == 3  # Manual-review items remain available to inspect.

    resources = directory / "Fake.app/Contents/Resources"
    resources.mkdir(parents=True)
    for name in ("foldy_setup.py", "bendy_hooks.py"):
        shutil.copyfile(Path(__file__).with_name(name), resources / name)
    subprocess.run([sys.executable, str(resources / "foldy_setup.py"), "--help"],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    subprocess.run([sys.executable, "-B", "-c", "import bendy_hooks; assert '/opt/homebrew/bin' in bendy_hooks.CLI_ENV['PATH'].split(':'); assert '/usr/local/bin' in bendy_hooks.CLI_ENV['PATH'].split(':')"],
                   cwd=resources, env=dict(os.environ, PATH="/usr/bin:/bin:/usr/sbin:/sbin"), check=True)
    assert not (resources / "__pycache__").exists()


def check():
    with tempfile.TemporaryDirectory(prefix="foldy-setup-check-") as temporary:
        directory = Path(temporary)
        turn_metadata_check(directory)
        codex_dir = directory / '中文.user "config"'
        codex_dir.mkdir()
        (codex_dir / "config.toml").write_text("# An unrelated user setting\n")
        hooks_file = codex_dir / "hooks.json"
        other = {"type": "command", "command": "/usr/bin/true", "timeout": 8}
        original = {"metadata": "keep", "hooks": {
            "SessionStart": [{"matcher": "startup", "hooks": [other]}],
            "CustomEvent": [{"hooks": [other]}]}}
        setup.save(hooks_file, original)
        root = directory / 'Support "Folder" 中文'
        config_dir = (directory / "Feishu CLI").resolve()
        cli_args, batches, trusts = [], [], {}
        identity = {"appId": "cli_example123", "identities": {
            "user": {"status": "ready", "available": True, "verified": True,
                     "openId": "ou_123abc", "userName": "测试账号", "tokenStatus": "valid"},
            "bot": {"status": "ready", "available": True, "verified": True}}}
        modes = {"untrusted": False, "changed_hash": False, "bad_hash": False,
                 "logged_out": False, "expired_codex": False}

        def run(command, **kwargs):
            assert command[1:] == ["auth", "status", "--json", "--verify"]
            assert kwargs["env"]["LARKSUITE_CLI_CONFIG_DIR"] == str(config_dir)
            assert kwargs["timeout"] == 20
            cli_args.append(command)
            return SimpleNamespace(returncode=0, stdout=json.dumps(identity))

        class Server:
            def __init__(self, executable, deadline):
                self.after_write = False

            def send(self, notification):
                assert notification["method"] == "initialized"

            def close(self):
                pass

            def call(self, method, params):
                if method == "initialize":
                    assert params["capabilities"]["experimentalApi"]
                    return {}
                if method == "account/read":
                    return {"account": None if modes["logged_out"] else {"type": "chatgpt"}}
                if method == "account/rateLimits/read":
                    if modes["expired_codex"]:
                        raise RuntimeError("expired credentials")
                    return {"rateLimits": {}}
                if method == "config/read":
                    return {"layers": [{"name": {"type": "user", "file": str(codex_dir / "config.toml"),
                                                   "profile": None}, "version": "version-1"}]}
                if method == "hooks/list":
                    items = []
                    data = setup.load(hooks_file, {})
                    for event, groups in data["hooks"].items():
                        if event not in setup.EVENTS:
                            continue
                        for group_index, group in enumerate(groups):
                            for hook_index, hook in enumerate(group["hooks"]):
                                key = "%s:%s:%s:%s" % (hooks_file, event, group_index, hook_index)
                                digest = "sha256:" + hashlib.sha256(key.encode()).hexdigest()
                                if modes["changed_hash"] and self.after_write:
                                    digest = "sha256:" + "f" * 64
                                if modes["bad_hash"]:
                                    digest = "not-a-valid-hash"
                                trusted = trusts.get(key) == digest and not modes["untrusted"]
                                items.append({"key": key, "eventName": setup.EVENTS[event],
                                    "sourcePath": str(hooks_file), "source": "user", "isManaged": False,
                                    "handlerType": "command", "command": hook["command"],
                                    "currentHash": digest, "trustStatus": "trusted" if trusted else "untrusted",
                                    "enabled": True})
                    return {"data": [{"hooks": items, "errors": []}]}
                if method == "config/batchWrite":
                    assert params["filePath"] == str(codex_dir / "config.toml")
                    assert params["expectedVersion"] == "version-1"
                    assert params["reloadUserConfig"] is True
                    assert len(params["edits"]) == 14
                    batches.append(copy.deepcopy(params))
                    for edit in params["edits"]:
                        assert edit["mergeStrategy"] == "upsert"
                        assert edit["keyPath"].startswith('hooks.state."')
                        for suffix in (".trusted_hash", ".enabled"):
                            if edit["keyPath"].endswith(suffix):
                                literal = edit["keyPath"][len("hooks.state."):-len(suffix)]
                                key = json.loads(literal)
                                assert '中文.user "config"' in key
                                assert ":SessionStart:0:0" not in key  # Never trust someone else's command.
                                if suffix == ".trusted_hash":
                                    trusts[key] = edit["value"]
                                else:
                                    assert edit["value"] is True
                                break
                        else:
                            assert False, "Whole-table or unexpected config edit"
                    self.after_write = True
                    return {"status": "ok"}
                raise AssertionError("Unexpected RPC, especially a send or task start: " + method)

        def finish(**overrides):
            return setup.finish(sys.executable, config_dir, sys.executable, codex=sys.executable,
                                root=root, codex_dir=codex_dir, run=run,
                                server_factory=Server, **overrides)

        assert finish()["ok"]
        connected = setup.load(root / "config.json", {})
        assert connected["account_name"] == "测试账号"
        assert connected["recipient_open_id"] == "ou_123abc"
        assert connected["app_id"] == "cli_example123"
        assert connected["account_open_id"] == connected["recipient_open_id"]
        assert connected["as"] == "bot"
        assert connected["codex_home"] == str(codex_dir)
        notification_check(directory, connected, identity)
        for file in (root / "config.json", root / "bendy_hooks.py", hooks_file, root / "hooks.previous.json"):
            assert stat.S_IMODE(file.stat().st_mode) == 0o600
        merged = setup.load(hooks_file, {})
        assert merged["metadata"] == original["metadata"]
        assert merged["hooks"]["CustomEvent"] == original["hooks"]["CustomEvent"]
        assert merged["hooks"]["SessionStart"][0] == original["hooks"]["SessionStart"][0]
        argv = shlex.split(merged["hooks"]["Stop"][0]["hooks"][0]["command"])
        assert argv == [sys.executable, str(root / "bendy_hooks.py"), "codex-event"]
        hooks_bytes = hooks_file.read_bytes()
        conf_bytes = (root / "config.json").read_bytes()
        assert finish()["ok"] and len(batches) == 1
        assert hooks_file.read_bytes() == hooks_bytes
        assert (root / "config.json").read_bytes() == conf_bytes

        # Same argv with legacy double quotes stays in the same slot and is not duplicated.
        legacy = {"hooks": {"Stop": [{"hooks": [{"type": "command", "command":
            '/usr/bin/python3 "' + str(directory / "plain space/bendy_hooks.py") + '" codex-event'}]}]}}
        setup.merge_hooks(legacy, Path("/usr/bin/python3"), directory / "plain space/bendy_hooks.py")
        assert len(legacy["hooks"]["Stop"]) == 1

        identity["identities"]["user"]["openId"] = "ou_another456"
        assert finish()["stage"] == "account_changed"
        assert (root / "config.json").read_bytes() == conf_bytes
        assert finish(replace_existing=True)["ok"]
        assert (root / "config.previous.json").read_bytes() == conf_bytes
        changed = setup.load(root / "config.json", {})
        assert changed["connection_id"] != connected["connection_id"]
        current_bytes = (root / "config.json").read_bytes()

        for flag in ("untrusted", "changed_hash", "bad_hash", "logged_out", "expired_codex"):
            trusts.clear()
            modes[flag] = True
            result = finish()
            assert not result["ok"], (flag, result)
            assert (root / "config.json").read_bytes() == current_bytes
            modes[flag] = False
        identity["identities"]["bot"]["verified"] = False
        assert finish()["stage"] == "feishu"
        assert (root / "config.json").read_bytes() == current_bytes
        identity["identities"]["bot"]["verified"] = True
        (root / "config.json").unlink()
        modes["logged_out"] = True
        assert not finish()["ok"] and not (root / "config.json").exists()
        assert len(cli_args) >= 8
        assert (codex_dir / "config.toml").read_text() == "# An unrelated user setting\n"
    print("PASS: fresh turn metadata and quota-cache branch, GUI CLI PATH and launch failures, no retry starvation, preserved hooks, exact trust edits, isolated accounts, no Resources bytecode and 0600 permissions")


if __name__ == "__main__":
    check()
