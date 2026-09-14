#!/usr/bin/env python3
"""Foldy lid notifications. No model calls, transcript reads, or embedded credentials."""
import argparse
import contextlib
import datetime as dt
import fcntl
import json
import math
import os
from pathlib import Path
import re
import selectors
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path.home() / "Library/Application Support/Bendy Replica/Hooks"
EVENTS = {"UserPromptSubmit": "running", "PreToolUse": "running",
          "PostToolUse": "running", "PermissionRequest": "attention",
          "Stop": "idle", "Interrupt": "interrupted", "SessionEnd": "ended"}
STALE_SECONDS = 6 * 3600
CLI_ENV = dict(os.environ, LARKSUITE_CLI_NO_UPDATE_NOTIFIER="1",
               LARKSUITE_CLI_NO_SKILLS_NOTIFIER="1")
CLI_ENV["PATH"] = os.pathsep.join(dict.fromkeys(filter(None, [
    *os.environ.get("PATH", "").split(os.pathsep), "/opt/homebrew/bin", "/usr/local/bin",
    str(Path.home() / ".local/bin"), "/usr/bin", "/bin", "/usr/sbin", "/sbin"])))
CLI_START_ERROR = "飞书 CLI 未能启动（可能缺少 Node 或执行权限），消息未发送；请重新安装飞书 CLI。"


def clean(value, limit=100):
    return " ".join(str(value or "").split())[:limit]


def load(path, default):
    try:
        with path.open() as f:
            value = json.load(f)
        if not isinstance(value, dict):
            raise ValueError("invalid state")
        return value
    except FileNotFoundError:
        return default


def save(path, value):
    fd, name = tempfile.mkstemp(prefix=".bendy-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(value, f, ensure_ascii=False, separators=(",", ":"))
            f.flush()
            os.fsync(f.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


@contextlib.contextmanager
def lock(root, name="state", wait=True):
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (root / (name + ".lock")).open("a") as f:
        fcntl.flock(f, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
        yield


@contextlib.contextmanager
def state(root):
    with lock(root):
        data = load(root / "state.json", {})
        yield data
        save(root / "state.json", data)


def config(root):
    return load(root / "config.json", {})


def event_uuid(value):
    return str(uuid.UUID(value))


def record(data, event, now):
    kind, sid = event.get("hook_event_name"), event.get("session_id")
    if not isinstance(sid, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,100}", sid):
        return
    if event.get("agent_id") or str(kind).startswith("Subagent"):
        return
    tasks = data.setdefault("tasks", {})
    if kind not in EVENTS and kind != "SessionStart":
        return
    old = tasks.get(sid, {})
    # A compaction/resume is not proof that an existing running turn stopped.
    if kind == "SessionStart" and old:
        return
    turn = clean(event.get("turn_id"), 100)
    if kind == "Stop" and turn and old.get("turn_id") and turn != old["turn_id"]:
        return  # A delayed stop from the previous turn must not stop the new one.
    tasks[sid] = {"status": EVENTS.get(kind, "unknown"), "updated_at": now,
                  "event": kind, "turn_id": turn,
                  "project": clean(Path(str(event.get("cwd") or "Codex")).name)}
    # ponytail: keep 500 task states; a database is unnecessary for a personal notifier.
    data["tasks"] = dict(sorted(tasks.items(), key=lambda kv: kv[1]["updated_at"])[-500:])


class AppServer:
    def __init__(self, executable, deadline):
        self.deadline, self.buffer, self.next_id = deadline, b"", 0
        self.proc = subprocess.Popen([executable, "app-server"], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.proc.stdout, selectors.EVENT_READ)

    def send(self, value):
        self.proc.stdin.write((json.dumps(value) + "\n").encode())
        self.proc.stdin.flush()

    def call(self, method, params):
        self.next_id += 1
        request_id = self.next_id
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        while time.monotonic() < self.deadline:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                response = json.loads(line)
                if response.get("id") == request_id:
                    if "error" in response:
                        raise RuntimeError("Codex 读取失败")
                    return response.get("result", {})
            if not self.selector.select(max(0, self.deadline - time.monotonic())):
                break
            chunk = os.read(self.proc.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("Codex 连接结束")
            self.buffer += chunk
            if len(self.buffer) > 4 * 1024 * 1024:
                raise RuntimeError("Codex 响应过大")
        raise TimeoutError("Codex 读取超时")

    def close(self):
        self.selector.close()
        self.proc.terminate()
        try:
            self.proc.wait(timeout=0.5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.proc.stdin.close()
        self.proc.stdout.close()


def turn_metadata(row, path):
    if not row:
        return None
    try:
        if Path(path).stat().st_size != row[4]:
            return None
    except OSError:
        return None
    turn_id, status, started, completed, _ = row
    mapped = {"inProgress": "running", "completed": "idle", "interrupted": "interrupted", "failed": "failed"}.get(status)
    updated = started if status == "inProgress" else completed
    if not mapped or not isinstance(started, (int, float)) or not isinstance(updated, (int, float)):
        return None
    return {"status": mapped, "turn_id": turn_id, "updated_at": updated,
            "started_at": started, "source": "turn_metadata"}


def latest_turn_states(threads, codex_home=None):
    """Read turn metadata only; lagging projections cannot describe the current turn."""
    home = Path(codex_home or os.environ.get("CODEX_HOME") or Path.home() / ".codex").expanduser().absolute()
    result = {}
    try:
        # These are versioned local schemas, not an API. Unknown versions remain unknown.
        with contextlib.closing(sqlite3.connect((home / "thread_history_1.sqlite").as_uri() + "?mode=ro", uri=True, timeout=.1)) as history, \
             contextlib.closing(sqlite3.connect((home / "state_5.sqlite").as_uri() + "?mode=ro", uri=True, timeout=.1)) as catalog:
            deadline = time.monotonic() + .25
            history.set_progress_handler(lambda: time.monotonic() > deadline, 1000)
            catalog.set_progress_handler(lambda: time.monotonic() > deadline, 1000)
            for thread in threads[:100]:
                if time.monotonic() > deadline:
                    break
                path = catalog.execute("SELECT rollout_path FROM threads WHERE id=?", (thread["id"],)).fetchone()
                if not path or not path[0]:
                    continue
                segment = re.search(r"([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\.jsonl$", Path(path[0]).name)
                if not segment:
                    continue
                # Projection keys identify this immutable segment, not the stable task ID.
                row = history.execute("SELECT t.turn_id,t.status,t.started_at,t.completed_at,p.next_rollout_byte_offset "
                    "FROM thread_turns t JOIN thread_history_projection_state p ON p.thread_id=t.thread_id "
                    "WHERE t.thread_id=? ORDER BY t.rollout_ordinal DESC LIMIT 1", (segment.group(1),)).fetchone()
                observed = turn_metadata(row, path[0])
                if observed:
                    result[thread["id"]] = observed
    except (OSError, ValueError, sqlite3.Error, KeyError, TypeError):
        pass
    return result


def refresh(root, conf, now=None):
    now = now or time.time()
    with lock(root):
        cached = load(root / "state.json", {}).get("snapshot", {})
    if now - cached.get("fetched_at", 0) < 30:
        cached["turn_states"] = latest_turn_states(cached.get("threads", []), conf.get("codex_home"))
        with state(root) as data:
            data.setdefault("snapshot", {})["turn_states"] = cached["turn_states"]
        return cached
    result = dict(cached)
    server = None
    try:
        executable = conf.get("codex_path")
        if not executable or not Path(executable).is_file():
            raise RuntimeError("未配置 Codex 命令")
        server = AppServer(executable, time.monotonic() + 5.5)
        server.call("initialize", {"clientInfo": {"name": "bendy_hooks", "version": "1"},
                                   "capabilities": {"experimentalApi": True}})
        server.send({"jsonrpc": "2.0", "method": "initialized"})
        result.update(quota=server.call("account/rateLimits/read", {}), quota_at=now)
        # Metadata only: never scan or parse chat transcripts, even for title repair.
        listed = server.call("thread/list", {"limit": 100, "sortKey": "updated_at",
                             "sourceKinds": ["cli", "vscode", "appServer", "exec"],
                             "useStateDbOnly": True})
        result["threads"] = [{"id": t["id"], "session_id": t.get("sessionId", t["id"]),
                              "title": clean(t.get("name"), 80), "updated_at": t["updatedAt"],
                              "project": clean(Path(t.get("cwd") or "Codex").name)}
                             for t in listed.get("data", [])
                             if isinstance(t.get("source"), str) and not t.get("agentRole")]
        result.update(threads_at=now, partial=bool(listed.get("nextCursor")), fetched_at=now)
        result.pop("error", None)
    except (OSError, ValueError, KeyError, RuntimeError, TimeoutError):
        result["error"] = "Codex 信息暂不可用；已有数据标注缓存时间"
    finally:
        if server:
            server.close()
    result["turn_states"] = latest_turn_states(result.get("threads", []), conf.get("codex_home"))
    with state(root) as data:
        previous = data.get("snapshot", {})
        if result.get("quota_at", 0) >= previous.get("quota_at", 0):
            data["snapshot"] = result
    return result


def local_time(timestamp):
    return dt.datetime.fromtimestamp(timestamp).astimezone().strftime("%m-%d %H:%M %Z")


def newer_turn(candidate, previous):
    try:
        candidate, previous = uuid.UUID(candidate), uuid.UUID(previous)
        return candidate.version == previous.version == 7 and candidate.int > previous.int
    except (ValueError, TypeError, AttributeError):
        return False


def current_task_state(event, recorded):
    if not recorded:
        return event
    if not event:
        return recorded
    if newer_turn(recorded.get("turn_id"), event.get("turn_id")):
        return recorded
    if newer_turn(event.get("turn_id"), recorded.get("turn_id")):
        return event
    if event.get("status") in ("unknown", "stale"):
        return recorded
    if (recorded.get("turn_id") and recorded.get("turn_id") == event.get("turn_id")
            and recorded["status"] in ("idle", "interrupted", "failed")):
        return recorded  # Metadata timestamps are whole seconds; hook clocks are fractional.
    # A turn stays inProgress while awaiting permission; only a new hook or its
    # observed completion can resolve that waiting state.
    if event.get("status") == "attention" and recorded["status"] == "running":
        return event
    return recorded if recorded["updated_at"] > event.get("updated_at", 0) else event


def task_rows(data, at, since=None):
    start = dt.datetime.fromtimestamp(at).replace(hour=0, minute=0, second=0, microsecond=0).timestamp() if since is None else since
    tasks, rows = data.get("tasks", {}), {}
    for item in data.get("snapshot", {}).get("threads", []):
        event = tasks.get(item.get("session_id")) or tasks.get(item["id"], {})
        recorded = data.get("snapshot", {}).get("turn_states", {}).get(item["id"])
        event = current_task_state(event, recorded)
        updated = max(item.get("updated_at", 0), event.get("updated_at", 0))
        if updated < start and event.get("status") not in ("running", "attention"):
            continue
        status = event.get("status", "unknown")
        if status in ("running", "attention") and at - event.get("updated_at", 0) > STALE_SECONDS:
            status = "stale"
        rows[item["id"]] = dict(item, status=status, updated_at=updated, turn_id=event.get("turn_id", ""),
                               status_source=event.get("source", "hook"))
    return sorted(rows.values(), key=lambda r: ({"attention": 0, "running": 1, "stale": 2,
                  "unknown": 3}.get(r["status"], 4), -r["updated_at"]))


def guardian_status(root=ROOT, codex_home=None, now=None, tracked_ids=()):
    """Read-only, bounded observation for power policy; never infer idle from failure."""
    at = time.time() if now is None else now
    result = {"ok": True, "checked_at": at, "active_count": 0, "running": [], "tasks": [],
              "waiting_count": 0, "unknown_count": 0, "trustworthy": False, "reason": "metadata_unavailable"}
    deadline = time.monotonic() + .25
    try:
        tracked = list(dict.fromkeys(tracked_ids))
        if len(tracked) > 100 or any(not isinstance(sid, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,100}", sid) for sid in tracked):
            result["reason"] = "invalid_task_ids"
            return result
        # Atomic replacement makes a read lock unnecessary. Do not create state/config.
        for path in (root / "state.json", root / "config.json"):
            if path.exists() and path.stat().st_size > 8 * 1024 * 1024:
                result["reason"] = "state_too_large"
                return result
        conf = config(root)
        home = Path(codex_home or conf.get("codex_home") or os.environ.get("CODEX_HOME")
                    or Path.home() / ".codex").expanduser().absolute()
        if not (home / "state_5.sqlite").is_file():
            result["reason"] = "missing_catalog"
            return result
        if not (home / "thread_history_1.sqlite").is_file():
            return result
        events = load(root / "state.json", {}).get("tasks", {})
        if not isinstance(events, dict) or len(events) > 500:
            result["reason"] = "invalid_state"
            return result
        outstanding = list(dict.fromkeys(tracked + [sid for sid, event in events.items()
            if event.get("status") in ("running", "attention") and at - event.get("updated_at", 0) <= STALE_SECONDS]))
        with contextlib.closing(sqlite3.connect((home / "state_5.sqlite").as_uri() + "?mode=ro", uri=True, timeout=.02)) as db:
            db.set_progress_handler(lambda: time.monotonic() > deadline, 1000)
            db.execute("ATTACH DATABASE ? AS history", ((home / "thread_history_1.sqlite").as_uri() + "?mode=ro",))
            # Track previously running IDs even overnight. Old unrelated inProgress
            # remnants after a crash must not block every future clear observation.
            query = """SELECT t.id,COALESCE(NULLIF(t.name,''),t.title),t.updated_at,t.cwd,t.rollout_path,
                       h.turn_id,h.status,h.started_at,h.completed_at,p.next_rollout_byte_offset
                FROM threads t LEFT JOIN history.thread_turns h
                  ON h.thread_id=substr(t.rollout_path,-42,36) AND h.rollout_ordinal=(
                    SELECT MAX(last.rollout_ordinal) FROM history.thread_turns last
                    WHERE last.thread_id=substr(t.rollout_path,-42,36))
                LEFT JOIN history.thread_history_projection_state p ON p.thread_id=h.thread_id
                WHERE t.source IN ('cli','vscode','appServer','exec')
                  AND (t.agent_role IS NULL OR t.agent_role='')
                  AND ((t.archived=0 AND t.updated_at>=?) OR t.id IN (%s))
                ORDER BY t.id IN (%s) DESC,t.updated_at DESC LIMIT 101""" % (
                    ",".join("?" for _ in outstanding) or "NULL", ",".join("?" for _ in tracked) or "NULL")
            records = db.execute(query, (at - 86400, *outstanding, *tracked)).fetchall()
        threads, turns = [], {}
        for row in records[:100]:
            if time.monotonic() > deadline:
                result["reason"] = "timeout"
                return result
            sid, title, updated, cwd, path = row[:5]
            threads.append({"id": sid, "session_id": sid, "title": clean(title, 80),
                            "updated_at": updated, "project": clean(Path(cwd).name)})
            if re.search(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\.jsonl$", Path(path).name):
                observed = turn_metadata(row[5:], path)
                if observed:
                    turns[sid] = observed
        # Preserve an outstanding Hook even before its catalog row arrives. It cannot
        # be declared complete just because the database has not caught up.
        known = {t["id"] for t in threads}
        for sid in outstanding:
            if sid not in known:
                event = events.get(sid, {})
                threads.append({"id": sid, "session_id": sid, "title": "", "project": event.get("project", "Codex"),
                                "updated_at": at if sid in tracked else event.get("updated_at", 0)})
        rows = task_rows({"tasks": events, "snapshot": {"threads": threads, "turn_states": turns}}, at, since=0)
        rows.sort(key=lambda r: r["id"] not in tracked)
        result["tasks"] = [{"id": r["id"], "title": r["title"] or r["project"], "status": r["status"],
                            "turn_id": r["turn_id"], "source": r["status_source"] if r["status"] != "unknown" else "unknown"}
                           for r in rows[:100]]
        result["running"] = [r for r in result["tasks"] if r["status"] == "running"]
        result["active_count"] = len(result["running"])
        result["waiting_count"] = sum(r["status"] == "attention" for r in rows)
        result["unknown_count"] = sum(r["status"] in ("unknown", "stale") for r in rows)
        partial = len(records) > 100 or len(rows) > 100
        result["trustworthy"] = not partial and not result["unknown_count"]
        result["reason"] = "partial" if partial else "unknown_tasks" if result["unknown_count"] else "observed"
    except (OSError, ValueError, sqlite3.Error, KeyError, TypeError, AttributeError):
        if time.monotonic() > deadline:
            result["reason"] = "timeout"
    return result


def quota_lines(snapshot, at):
    quota = snapshot.get("quota", {})
    buckets = quota.get("rateLimitsByLimitId") or {"codex": quota.get("rateLimits")}
    lines = []
    for key, bucket in sorted(buckets.items(), key=lambda kv: kv[0] != "codex"):
        if not isinstance(bucket, dict):
            continue
        for field in ("primary", "secondary"):
            window = bucket.get(field)
            if not isinstance(window, dict):
                continue
            used, minutes, reset = (window.get(k) for k in ("usedPercent", "windowDurationMins", "resetsAt"))
            if not isinstance(used, (int, float)) or not math.isfinite(used):
                continue
            label = {10080: "周额度", 300: "5 小时额度"}.get(minutes,
                    "%s 分钟额度" % minutes if minutes else "额度（周期未知）")
            name = clean(bucket.get("limitName") or ("Codex" if key == "codex" else key), 50)
            remaining = max(0, min(100, 100 - used))
            if isinstance(reset, (int, float)) and reset <= at:
                lines.append("• %s %s：缓存已过重置时间，剩余未知" % (name, label))
            else:
                suffix = "；%s 重置" % local_time(reset) if isinstance(reset, (int, float)) else "；重置时间未知"
                lines.append("• %s %s：剩余 %g%%%s" % (name, label, remaining, suffix))
    if not lines:
        return ["• 额度暂不可用（不是 0）；请确认 Codex 已登录"]
    if at - snapshot.get("quota_at", 0) > 60:
        lines.append("额度缓存：" + local_time(snapshot["quota_at"]))
    return lines


def message_text(data, item, at):
    heading = "Foldy 安装测试 · Codex 离开前摘要" if item.get("test") else "Foldy 合盖交接 · Codex 摘要"
    lines = [heading, "合盖事件：" + local_time(item["created_at"])]
    if at - item["created_at"] > 60:
        lines.append("这是之前合盖事件的补发；以下是 %s 的状态快照。" % local_time(at))
    rows = task_rows(data, at)
    active = [r for r in rows if r["status"] in ("running", "attention")]
    unknown = [r for r in rows if r["status"] in ("unknown", "stale")]
    lines.extend(["", "今天的本机任务：已观察到 %d 个运行 / 待处理，%d 个状态未知。" % (len(active), len(unknown))])
    labels = {"running": "运行中", "attention": "等待处理", "unknown": "状态未知", "stale": "状态已过期"}
    for row in (active + unknown)[:12]:
        name = row["title"] or "%s · %s" % (row["project"], row["id"][:8])
        label = labels[row["status"]]
        if row["status_source"] == "turn_metadata" and row["status"] == "running":
            label = "运行中·本机记录"
        lines.append("• [%s] %s" % (label, name))
    if len(active) + len(unknown) > 12:
        lines.append("另有 %d 个任务未展开。" % (len(active) + len(unknown) - 12))
    completed = sum(r["status"] == "idle" for r in rows)
    if completed:
        lines.append("今天已结束本轮回复：%d 个任务（不代表整个项目完成）。" % completed)
    if not rows:
        lines.append("尚未读到今天的任务；不能据此判断没有任务在运行。")
    lines.append("状态结合本机 Codex 事件与最近回合记录；“本机记录”在异常退出后可能未更新，记录缺失或过期显示未知。合盖休眠后本机任务可能暂停。")
    if data.get("snapshot", {}).get("partial"):
        lines.append("任务列表限最近 100 条，可能不完整。")
    lines.extend(["", "账号共享额度（并非每日或单任务额度）："])
    lines.extend(quota_lines(data.get("snapshot", {}), at))
    return "\n".join(lines)


def enqueue(root, eid, is_test=False, now=None):
    with state(root) as data:
        outbox = data.setdefault("outbox", {})
        outbox.setdefault(eid, {"created_at": now or time.time(), "status": "pending", "test": is_test,
                               "connection_id": config(root).get("connection_id")})
        # Keep pending/uncertain events; only old confirmed receipts are pruned.
        cutoff = time.time() - 30 * 86400
        data["outbox"] = {k: v for k, v in outbox.items()
                          if v["status"] != "sent" or v.get("sent_at", 0) >= cutoff}


def send_cli(conf, item, eid):
    environment = dict(CLI_ENV)
    if conf.get("lark_config_dir"):
        environment["LARKSUITE_CLI_CONFIG_DIR"] = conf["lark_config_dir"]
    if conf.get("connection_id"):
        if (item.get("connection_id") != conf["connection_id"]
                or item.get("recipient") != conf.get("account_open_id") or item.get("as") != "bot"):
            return {"ok": False, "uncertain": False, "error": "待发摘要与当前飞书连接不一致，已停止发送"}
        try:
            checked = subprocess.run([conf["lark_path"], "auth", "status", "--json", "--verify"],
                                     capture_output=True, text=True, timeout=8, env=environment)
            if checked.returncode in (126, 127):
                return {"ok": False, "uncertain": False, "error": CLI_START_ERROR}
            account = json.loads(checked.stdout)
            user = account.get("identities", {}).get("user", {})
            bot = account.get("identities", {}).get("bot", {})
            if (checked.returncode != 0 or account.get("appId") != conf.get("app_id")
                    or user.get("openId") != conf.get("account_open_id")
                    or not all(identity.get("verified") is True and identity.get("available") is True
                               and identity.get("status") == "ready" for identity in (user, bot))):
                return {"ok": False, "uncertain": False, "error": "飞书账号已变化或登录已失效，请在 Foldy 中重新连接"}
        except (FileNotFoundError, PermissionError):
            return {"ok": False, "uncertain": False, "error": CLI_START_ERROR}
        except (OSError, ValueError, TypeError, AttributeError, subprocess.TimeoutExpired):
            return {"ok": False, "uncertain": False, "error": "暂时无法确认飞书账号，已保留待发摘要"}
    command = [conf["lark_path"], "im", "+messages-send", "--as", item["as"],
               "--user-id", item["recipient"], "--text", item["text"],
               "--idempotency-key", "bendy-" + eid, "--format", "json"]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=8, env=environment)
        if result.returncode in (126, 127):
            return {"ok": False, "uncertain": False, "error": CLI_START_ERROR}
        payload = json.loads(result.stdout if result.returncode == 0 else result.stderr)
        mid = payload.get("data", {}).get("message_id")
        if result.returncode == 0 and payload.get("ok") is True and isinstance(mid, str) and mid:
            return {"ok": True, "message_id": mid}
        error = payload.get("error", {})
        definite = payload.get("ok") is False and error.get("type") in ("authorization", "validation", "confirmation")
        return {"ok": False, "uncertain": not definite, "error": "飞书发送失败（%s）" % clean(error.get("type") or "响应未确认", 50)}
    except subprocess.TimeoutExpired:
        return {"ok": False, "uncertain": True, "error": "飞书发送超时，结果待确认"}
    except (FileNotFoundError, PermissionError):
        return {"ok": False, "uncertain": False, "error": CLI_START_ERROR}
    except (OSError, ValueError, TypeError):
        return {"ok": False, "uncertain": True, "error": "飞书未返回可确认的消息回执"}


def needs_review(item):
    return item.get("uncertain") and time.time() - item.get("first_attempt_at", 0) >= 3500


def deliver(root, eid, conf, sender=send_cli):
    with state(root) as data:
        item = data["outbox"][eid]
        if item["status"] == "sent":
            return {"ok": True, "message": "这次合盖摘要已发送", "message_id": item["message_id"]}
        # Feishu deduplicates for one hour only. Never blindly resend an uncertain old write.
        if needs_review(item):
            item.update(status="uncertain", error="上次发送结果不确定且已超过幂等窗口，需人工核对飞书")
            return {"ok": False, "message": item["error"]}
        recipient, identity = conf.get("recipient_open_id", ""), conf.get("as", "bot")
        if not re.fullmatch(r"ou_[A-Za-z0-9]+", recipient) or identity not in ("bot", "user"):
            return {"ok": False, "message": "请先配置飞书收件人和发送身份"}
        if not conf.get("lark_path") or not Path(conf["lark_path"]).is_file():
            return {"ok": False, "message": "请先配置飞书 CLI 路径"}
        if item.get("connection_id") != conf.get("connection_id"):
            return {"ok": False, "message": "这条待发摘要属于之前的飞书连接，已保留，请核对后处理"}
        # Freeze recipient/content with the idempotency key before the first network write.
        item.setdefault("connection_id", conf.get("connection_id"))
        item.setdefault("recipient", recipient)
        item.setdefault("as", identity)
        item.setdefault("text", message_text(data, item, time.time()))
        item.setdefault("first_attempt_at", time.time())
        item.update(status="pending", uncertain=True, last_attempt_at=time.time())
        frozen = dict(item)
    result = sender(conf, frozen, eid)
    with state(root) as data:
        item = data["outbox"][eid]
        if result["ok"]:
            item.update(status="sent", sent_at=time.time(), message_id=result["message_id"], uncertain=False)
            item.pop("error", None)
        else:
            item.update(status="pending", uncertain=result.get("uncertain", True), error=result["error"])
        data["last_result"] = {"ok": result["ok"], "message": "飞书摘要已发送" if result["ok"] else result["error"],
                               "at": time.time(), "event_id": eid}
        return dict(data["last_result"], **({"message_id": result["message_id"]} if result["ok"] else {}))


def pending(root, ids=None, retryable_only=False, connection_id=None):
    with lock(root):
        queue = load(root / "state.json", {}).get("outbox", {})
    return [key for key, item in sorted(queue.items(), key=lambda kv: kv[1]["created_at"])
            if item["status"] != "sent" and (ids is None or key in ids)
            and (not retryable_only or (not needs_review(item) and item.get("connection_id") == connection_id))]


def send_pending(root, conf, ids=None):
    try:
        with lock(root, "send", wait=False):
            batch = pending(root, ids, retryable_only=True, connection_id=conf.get("connection_id"))[:2]
            if not batch:
                return {"ok": True, "message": "没有可自动补发的合盖摘要"}
            refresh(root, conf)
            results = [deliver(root, eid, conf) for eid in batch]
            return results[-1] if len(results) == 1 else {"ok": all(r["ok"] for r in results),
                    "message": "补发结果：" + "；".join(r["message"] for r in results)}
    except BlockingIOError:
        return {"ok": True, "message": "摘要已入队，发送进程正在处理"}


def self_test():
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        now = time.time()
        with state(root) as data:
            for kind, turn in [("UserPromptSubmit", "t1"), ("PermissionRequest", "t1")]:
                record(data, {"session_id": "root", "hook_event_name": kind, "turn_id": turn}, now)
            assert data["tasks"]["root"]["status"] == "attention"
            record(data, {"session_id": "root", "hook_event_name": "SubagentStop"}, now)
            record(data, {"session_id": "root", "hook_event_name": "SessionStart"}, now)
            assert data["tasks"]["root"]["status"] == "attention"
            record(data, {"session_id": "root", "hook_event_name": "UserPromptSubmit", "turn_id": "t2"}, now)
            record(data, {"session_id": "root", "hook_event_name": "Stop", "turn_id": "t1"}, now)
            assert data["tasks"]["root"]["status"] == "running"
            data["snapshot"] = {"threads": [{"id": "root", "session_id": "root", "title": "Test", "updated_at": now, "project": "Test"}]}
            assert task_rows(data, now)[0]["status"] == "running"
            assert task_rows(data, now + STALE_SECONDS + 1)[0]["status"] == "stale"
            data["tasks"] = {}
            assert task_rows(data, now)[0]["status"] == "unknown"
        eid = str(uuid.uuid4())
        enqueue(root, eid, now=now - 90)
        enqueue(root, eid)
        conf = {"recipient_open_id": "ou_test", "as": "bot", "lark_path": sys.executable}
        calls = []
        def failed(_, item, key):
            calls.append((key, item["text"]))
            return {"ok": False, "uncertain": True, "error": "timeout"}
        def success(_, item, key):
            calls.append((key, item["text"]))
            return {"ok": True, "message_id": "om_test"}
        assert not deliver(root, eid, conf, failed)["ok"]
        assert pending(root) == [eid]
        assert deliver(root, eid, conf, success)["ok"]
        assert deliver(root, eid, conf, success)["ok"] and len(calls) == 2
        assert calls[0] == calls[1] and "补发" in calls[0][1] and not pending(root)
        uncertain = str(uuid.uuid4())
        enqueue(root, uncertain)
        with state(root) as data:
            data["outbox"][uncertain].update(uncertain=True, first_attempt_at=now - 3601)
        assert not deliver(root, uncertain, conf, success)["ok"] and len(calls) == 2
        q = {"quota_at": now, "quota": {"rateLimits": {"primary": {"usedPercent": 4, "windowDurationMins": 10080, "resetsAt": now + 3600}}}}
        assert "剩余 96%" in quota_lines(q, now)[0]
        assert "剩余未知" in quota_lines(q, now + 4000)[0]
        assert "不是 0" in quota_lines({}, now)[0]
    return {"ok": True, "message": "离线检查通过：事件状态、过期、幂等、失败恢复、补发与额度"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["codex-event", "prepare", "close", "wake", "test", "status", "guardian-status", "self-test"])
    parser.add_argument("--event-id", type=event_uuid)
    parser.add_argument("--task-id", action="append", default=[], help="Keep observing a previously running task (guardian-status only)")
    args = parser.parse_args()
    if args.command == "self-test":
        result = self_test()
    elif args.command == "guardian-status":
        result = guardian_status(tracked_ids=args.task_id)
    elif args.command == "codex-event":
        try:
            event = json.loads(sys.stdin.read(1024 * 1024))
            with state(ROOT) as data:
                record(data, event, time.time())
        except (ValueError, OSError, AttributeError):
            pass  # Monitoring must never steer or fail the user's Codex turn.
        print("{}")
        return 0
    elif args.command == "status":
        with lock(ROOT):
            data = load(ROOT / "state.json", {})
        conf = config(ROOT)
        result = {"ok": True, "message": data.get("last_result", {}).get("message", "合盖提醒尚未发送"),
                  "configured": bool(conf.get("recipient_open_id") and conf.get("lark_path") and conf.get("codex_path")),
                  "pending": len(pending(ROOT)), "task_events": len(data.get("tasks", {})),
                  "last_result": data.get("last_result"), "quota_at": data.get("snapshot", {}).get("quota_at")}
    elif args.command == "prepare":
        if not args.event_id:
            parser.error("prepare requires --event-id")
        snapshot = refresh(ROOT, config(ROOT))
        result = {"ok": True, "message": snapshot.get("error", "Codex 摘要已准备"), "event_id": args.event_id}
    else:
        eid = args.event_id
        if args.command in ("close", "test"):
            if args.command == "test":
                eid = eid or str(uuid.uuid4())
            if not eid:
                parser.error("close requires --event-id")
            enqueue(ROOT, eid, is_test=args.command == "test")
        result = send_pending(ROOT, config(ROOT), [eid] if eid else None)
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError):
        print(json.dumps({"ok": False, "message": "合盖 Hook 配置或状态文件异常，请检查本地配置"}, ensure_ascii=False))
        sys.exit(1)
