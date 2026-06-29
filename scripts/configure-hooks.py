#!/usr/bin/env python3
"""Install or remove Agent Status-owned Codex and Claude hook entries."""

import argparse
import json
import os
import pathlib
import shutil
import stat
import sys


OWNER_ARGUMENT = "--agent-status-owner=v1"
CODEX_EVENTS = (
    "PermissionRequest",
    "PostCompact",
    "PostToolUse",
    "PreCompact",
    "PreToolUse",
    "SessionStart",
    "Stop",
    "UserPromptSubmit",
)
CLAUDE_EVENTS = (
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "PermissionRequest",
    "Notification",
    "SubagentStart",
    "SubagentStop",
    "PreCompact",
    "PostCompact",
    "SessionStart",
    "Stop",
    "StopFailure",
    "SessionEnd",
)


def read_object(path):
    if not path.exists():
        return {}
    with path.open(encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError("{} must contain a JSON object".format(path))
    return value


def atomic_write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(".{}.tmp-{}".format(path.name, os.getpid()))
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def is_owned(handler):
    return OWNER_ARGUMENT in str(handler.get("command", "")).split()


def owned_group(command, provider):
    handler = {
        "type": "command",
        "command": command,
        "timeout": 5,
    }
    if provider == "claude":
        handler["async"] = True
    return {"hooks": [handler]}


def hook_map(root):
    hooks = root.get("hooks")
    return hooks if isinstance(hooks, dict) else {}


def install_provider(provider, home, command):
    path = (
        home / ".codex" / "hooks.json"
        if provider == "codex"
        else home / ".claude" / "settings.json"
    )
    root = read_object(path)
    hooks = hook_map(root)
    events = CODEX_EVENTS if provider == "codex" else CLAUDE_EVENTS

    for event in events:
        groups = hooks.get(event)
        groups = groups if isinstance(groups, list) else []
        already_installed = any(
            isinstance(group, dict)
            and any(
                is_owned(handler)
                for handler in group.get("hooks", [])
                if isinstance(handler, dict)
            )
            for group in groups
        )
        if not already_installed:
            groups.append(owned_group(command, provider))
        hooks[event] = groups

    root["hooks"] = hooks
    atomic_write(path, root)


def uninstall_provider(provider, home):
    path = (
        home / ".codex" / "hooks.json"
        if provider == "codex"
        else home / ".claude" / "settings.json"
    )
    if not path.exists():
        return

    root = read_object(path)
    hooks = hook_map(root)
    for event in tuple(hooks):
        groups = hooks[event]
        if not isinstance(groups, list):
            continue
        remaining_groups = []
        for group in groups:
            if not isinstance(group, dict):
                remaining_groups.append(group)
                continue
            handlers = group.get("hooks")
            if not isinstance(handlers, list):
                remaining_groups.append(group)
                continue
            remaining_handlers = [
                handler
                for handler in handlers
                if not isinstance(handler, dict) or not is_owned(handler)
            ]
            if remaining_handlers:
                updated = dict(group)
                updated["hooks"] = remaining_handlers
                remaining_groups.append(updated)
        if remaining_groups:
            hooks[event] = remaining_groups
        else:
            hooks.pop(event, None)

    root["hooks"] = hooks
    atomic_write(path, root)


def install_hook(source, home):
    destination = (
        home
        / "Library"
        / "Application Support"
        / "AgentStatus"
        / "Hooks"
        / "agent-status-hook.py"
    )
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    shutil.copy2(source, destination)
    os.chmod(destination, stat.S_IRWXU)
    return destination


def selected_providers(value):
    return ("codex", "claude") if value == "all" else (value,)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("install", "uninstall"))
    parser.add_argument("--provider", choices=("all", "codex", "claude"), default="all")
    parser.add_argument("--hook", type=pathlib.Path)
    parser.add_argument("--home", type=pathlib.Path, default=pathlib.Path.home())
    arguments = parser.parse_args(argv)

    providers = selected_providers(arguments.provider)
    if arguments.action == "install":
        if arguments.hook is None or not arguments.hook.is_file():
            parser.error("install requires --hook pointing to the bundled hook")
        installed_hook = install_hook(arguments.hook, arguments.home)
        escaped = str(installed_hook).replace("'", "'\\''")
        for provider in providers:
            command = "'{}' --provider {} {}".format(
                escaped, provider, OWNER_ARGUMENT
            )
            install_provider(provider, arguments.home, command)
    else:
        for provider in providers:
            uninstall_provider(provider, arguments.home)
    return 0


if __name__ == "__main__":
    sys.exit(main())
