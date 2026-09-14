#!/usr/bin/env python3
"""Connect a verified local Feishu account to Foldy's Codex notification hooks."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True  # Imported helpers live in the signed app's Resources.
from bendy_hooks import AppServer, CLI_ENV, ROOT, clean, load, lock, save

EVENTS = {"SessionStart": "sessionStart", "UserPromptSubmit": "userPromptSubmit",
          "PermissionRequest": "permissionRequest", "PostToolUse": "postToolUse",
          "Stop": "stop", "Interrupt": "interrupt", "SessionEnd": "sessionEnd"}


class SetupError(Exception):
    def __init__(self, stage, message):
        self.stage, self.message = stage, message
        super().__init__(message)


def executable(value, label):
    path = Path(value).expanduser().absolute()
    if any(ord(c) < 32 for c in str(path)) or not path.is_file() or not os.access(path, os.X_OK):
        raise SetupError("dependencies", "找不到可运行的%s，请重新安装后重试。" % label)
    return path


def find_codex(override=None):
    if override:
        return executable(override, "Codex")
    # The desktop bundle can be newer than a leftover CLI on PATH.
    candidates = [base / app / "Contents/Resources/codex"
                  for base in (Path("/Applications"), Path.home() / "Applications")
                  for app in ("Codex.app", "ChatGPT.app")]
    fallback = shutil.which("codex", path=os.pathsep.join([
        os.environ.get("PATH", ""), str(Path.home() / ".local/bin"),
        "/opt/homebrew/bin", "/usr/local/bin"]))
    if fallback:
        candidates.append(Path(fallback))
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise SetupError("codex", "未找到 Codex。请先安装并登录 Codex，再点击连接。")


def feishu_identity(lark, config_dir, run=subprocess.run):
    env = dict(CLI_ENV, LARKSUITE_CLI_CONFIG_DIR=str(config_dir))
    try:
        result = run([str(lark), "auth", "status", "--json", "--verify"],
                     env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     text=True, timeout=20, check=False)
        if result.returncode or len(result.stdout) > 1024 * 1024:
            raise ValueError("status unavailable")
        value = json.loads(result.stdout)
        identities = value.get("identities", {})
        user, bot = identities.get("user", {}), identities.get("bot", {})
        if not all(item.get("available") is True and item.get("verified") is True
                   and item.get("status") == "ready" for item in (user, bot)):
            raise ValueError("identity unverified")
        app_id, open_id = value.get("appId", ""), user.get("openId", "")
        if not re.fullmatch(r"cli_[A-Za-z0-9]+", app_id) or not re.fullmatch(r"ou_[A-Za-z0-9]+", open_id):
            raise ValueError("identity missing")
        return app_id, open_id, clean(user.get("userName")) or "已连接的飞书账号"
    except (OSError, ValueError, TypeError, AttributeError, subprocess.TimeoutExpired):
        raise SetupError("feishu", "飞书账号或应用尚未验证成功，请完成授权后重试。") from None


def atomic_copy(source, destination):
    fd, name = tempfile.mkstemp(prefix=".foldy-", dir=destination.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(source.read_bytes())
            output.flush()
            os.fsync(output.fileno())
        os.replace(name, destination)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def merge_hooks(document, python, script):
    """Keep other hooks and their positions, which are part of Codex trust keys."""
    command = shlex.join([str(python), str(script), "codex-event"])
    argv = shlex.split(command)
    hooks = document.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("invalid hooks")
    commands = {}
    for event in EVENTS:
        groups = hooks.setdefault(event, [])
        if not isinstance(groups, list):
            raise ValueError("invalid event")
        owned = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                raise ValueError("invalid hook group")
            for hook in group["hooks"]:
                if not isinstance(hook, dict):
                    raise ValueError("invalid hook")
                if hook.get("type") != "command":
                    continue
                try:
                    parts = shlex.split(hook.get("command", ""))
                except ValueError:
                    continue
                if len(parts) == 3 and parts[1:] == argv[1:]:
                    # A Python update changes only our existing slot, never other trust keys.
                    if parts != argv:
                        hook["command"] = command
                    owned.append(hook["command"])
        if not owned:
            groups.append({"hooks": [{"type": "command", "command": command, "timeout": 2}]})
            owned.append(command)
        commands[EVENTS[event]] = set(owned)
    return commands


def owned_hooks(result, hooks_file, commands):
    found = {}
    for entry in result.get("data", []):
        if entry.get("errors"):
            raise SetupError("codex_hooks", "Codex Hook 配置存在错误，请在 Codex 中检查 /hooks。")
        for hook in entry.get("hooks", []):
            if (hook.get("sourcePath") != str(hooks_file) or hook.get("source") != "user"
                    or hook.get("handlerType") != "command" or hook.get("isManaged") is not False
                    or hook.get("command") not in commands.get(hook.get("eventName"), set())):
                continue
            key, digest = hook.get("key", ""), hook.get("currentHash", "")
            if (not key.startswith(str(hooks_file) + ":") or any(ord(c) < 32 for c in key)
                    or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest)):
                raise SetupError("codex_hooks", "Codex 未提供有效的 Hook 校验信息，请更新 Codex 后重试。")
            found[key] = hook
    if {hook["eventName"] for hook in found.values()} != set(EVENTS.values()):
        raise SetupError("codex_hooks", "Codex 未识别全部任务事件，请更新 Codex 后重试。")
    return found


def user_layer(server, cwd):
    result = server.call("config/read", {"includeLayers": True, "cwd": str(cwd)})
    for layer in result.get("layers") or []:
        name = layer.get("name", {})
        if name.get("type") == "user" and name.get("profile") is None and not layer.get("disabledReason"):
            path = Path(name.get("file", ""))
            if path.is_absolute() and layer.get("version"):
                return path, layer["version"]
    raise SetupError("codex_hooks", "无法读取 Codex 用户配置，请先启动并登录 Codex。")


def finish(lark, lark_config_dir, python, codex=None, replace_existing=False,
           root=ROOT, codex_dir=None, run=subprocess.run, server_factory=AppServer):
    stage, server = "dependencies", None
    try:
        root = Path(root).expanduser().absolute()
        config_dir = Path(lark_config_dir).expanduser().resolve()
        lark, python = executable(lark, "飞书 CLI"), executable(python, "Python")
        codex = find_codex(codex)
        stage = "feishu"
        app_id, open_id, account_name = feishu_identity(lark, config_dir, run)
        with lock(root, "setup"):
            conf_file = root / "config.json"
            previous = load(conf_file, {})
            changed_account = bool(previous and (
                previous.get("recipient_open_id") != open_id
                or previous.get("app_id", app_id) != app_id))
            if changed_account and not replace_existing:
                raise SetupError("account_changed", "已有其他飞书收件人，请确认更换账号后重新连接。")
            stage = "codex"
            server = server_factory(str(codex), time.monotonic() + 25)
            server.call("initialize", {"clientInfo": {"name": "foldy_setup", "version": "1"},
                                       "capabilities": {"experimentalApi": True}})
            server.send({"jsonrpc": "2.0", "method": "initialized"})
            account = server.call("account/read", {"refreshToken": False}).get("account")
            if not account:
                raise SetupError("codex", "Codex 尚未登录，请先在 Codex 中登录自己的账号。")
            if account.get("type") != "chatgpt":
                raise SetupError("codex", "请在 Codex 中登录 ChatGPT 账号，才能读取订阅剩余额度。")
            server.call("account/rateLimits/read", {})  # Verify saved auth still works, not only its presence.
            stage = "codex_hooks"
            config_file, _ = user_layer(server, root)
            actual_codex_dir = config_file.parent
            if codex_dir is not None and actual_codex_dir != Path(codex_dir).absolute():
                raise SetupError("codex_hooks", "Codex 配置位置不一致，已停止连接。")
            hooks_file = actual_codex_dir / "hooks.json"
            document = load(hooks_file, {})
            before = json.dumps(document, ensure_ascii=False, sort_keys=True)
            script = root / "bendy_hooks.py"
            commands = merge_hooks(document, python, script)
            atomic_copy(Path(__file__).with_name("bendy_hooks.py"), script)
            if json.dumps(document, ensure_ascii=False, sort_keys=True) != before:
                if hooks_file.exists():
                    atomic_copy(hooks_file, root / "hooks.previous.json")
                save(hooks_file, document)
            listed = owned_hooks(server.call("hooks/list", {"cwds": [str(root)]}), hooks_file, commands)
            edits = []
            for key, hook in listed.items():
                if hook.get("trustStatus") == "trusted" and hook.get("enabled") is True:
                    continue
                prefix = "hooks.state." + json.dumps(key, ensure_ascii=False)
                edits.extend([
                    {"keyPath": prefix + ".trusted_hash", "value": hook["currentHash"], "mergeStrategy": "upsert"},
                    {"keyPath": prefix + ".enabled", "value": True, "mergeStrategy": "upsert"}])
            if edits:
                _, version = user_layer(server, root)
                server.call("config/batchWrite", {"edits": edits, "expectedVersion": version,
                            "filePath": str(config_file), "reloadUserConfig": True})
            verified = owned_hooks(server.call("hooks/list", {"cwds": [str(root)]}), hooks_file, commands)
            if (set(verified) != set(listed) or any(
                    hook.get("trustStatus") != "trusted" or hook.get("enabled") is not True
                    or hook["currentHash"] != listed[key]["currentHash"]
                    for key, hook in verified.items())):
                raise SetupError("codex_hooks", "任务事件尚未获得 Codex 信任，请在 Codex 的 /hooks 中检查后重试。")
            stage = "save"
            connection_id = hashlib.sha256(json.dumps([str(config_dir), app_id, open_id],
                                                      ensure_ascii=False).encode()).hexdigest()
            connected = {"python_path": str(python), "lark_path": str(lark), "codex_path": str(codex),
                         "codex_home": str(actual_codex_dir),
                         "lark_config_dir": str(config_dir), "as": "bot", "recipient_open_id": open_id,
                         "account_name": account_name, "app_id": app_id, "account_open_id": open_id,
                         "connection_id": connection_id}
            if previous and previous != connected:
                atomic_copy(conf_file, root / "config.previous.json")
            save(conf_file, connected)
            return {"ok": True, "message": "已连接飞书并接入 Codex 任务状态；新的任务事件开始后自动更新。",
                    "account_name": account_name}
    except SetupError as error:
        return {"ok": False, "stage": error.stage, "error": error.message, "message": error.message}
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, TimeoutError):
        message = {"codex": "无法连接 Codex，请启动并登录新版 Codex 后重试。",
                   "codex_hooks": "无法接入 Codex 任务事件；原飞书配置已保留，请检查 Codex 配置后重试。",
                   "save": "无法保存连接配置，请检查本机文件权限后重试。"}.get(stage, "连接未完成，请检查安装与授权状态后重试。")
        return {"ok": False, "stage": stage, "error": message, "message": message}
    finally:
        if server:
            try:
                server.close()
            except OSError:
                pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["finish"])
    parser.add_argument("--lark", required=True)
    parser.add_argument("--lark-config-dir", required=True)
    parser.add_argument("--python", required=True)
    parser.add_argument("--codex")
    parser.add_argument("--replace-existing", action="store_true")
    args = parser.parse_args()
    result = finish(args.lark, args.lark_config_dir, args.python, args.codex, args.replace_existing)
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
