#!/usr/bin/env python3
"""Best-effort provider hook adapter for Agent Status."""

import json
import os
import socket
import subprocess
import sys


def argument_value(name):
    try:
        index = sys.argv.index(name)
        return sys.argv[index + 1]
    except (ValueError, IndexError):
        return None


def process_ancestry():
    names = []
    pid = os.getppid()
    for _ in range(12):
        if pid <= 1:
            break
        try:
            result = subprocess.run(
                ["ps", "-o", "ppid=,command=", "-p", str(pid)],
                capture_output=True,
                text=True,
                timeout=0.15,
                check=False,
            )
            parts = result.stdout.strip().split(None, 1)
            if len(parts) != 2:
                break
            pid = int(parts[0])
            names.append(parts[1].lower())
        except Exception:
            break
    return names


def provider_for(payload):
    explicit = argument_value("--provider")
    if explicit in ("codex", "claude"):
        return explicit
    value = str(payload.get("provider", "")).lower()
    if "claude" in value:
        return "claude"
    if "codex" in value:
        return "codex"
    ancestry = " ".join(process_ancestry())
    return "claude" if "claude" in ancestry else "codex"


def host_for(provider, payload):
    supplied = str(
        payload.get("host")
        or payload.get("host_application")
        or payload.get("client")
        or ""
    ).lower()
    ancestry = " ".join(process_ancestry())
    if provider == "claude":
        desktop = "desktop" in supplied or "claude.app/contents/" in ancestry
    else:
        desktop = "desktop" in supplied or "codex.app/contents/" in ancestry
    if provider == "claude":
        return "claudeDesktop" if desktop else "claudeCLI"
    return "codexDesktop" if desktop else "codexCLI"


def first_string(payload, keys):
    for key in keys:
        value = payload.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def activity_for(event, payload):
    normalized = event.lower().replace("_", "").replace("-", "")
    if normalized in ("stop", "stopfailure"):
        final_message = first_string(
            payload,
            ("last_assistant_message", "lastAssistantMessage"),
        )
        if final_message and "?" in final_message[-2000:]:
            return "waiting"
        return "finished"
    if normalized == "sessionend":
        return "ended"
    if normalized == "permissionrequest":
        return "waiting"
    if normalized == "notification":
        notification = str(
            payload.get("notification_type")
            or payload.get("notificationType")
            or payload.get("type")
            or ""
        ).lower()
        if any(word in notification for word in ("idle", "input", "permission", "approval")):
            return "waiting"
        return "working"
    if normalized == "sessionstart":
        return "idle"
    if normalized in (
        "userpromptsubmit",
        "pretooluse",
        "posttooluse",
        "posttoolusefailure",
        "subagentstart",
        "subagentstop",
        "precompact",
        "postcompact",
    ):
        return "working"
    return None


def socket_path():
    return "/tmp/agent-status-{}.sock".format(os.getuid())


def send_event(event):
    payload = json.dumps(event, separators=(",", ":")).encode("utf-8")
    try:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(0.15)
        try:
            connection.connect(socket_path())
            connection.sendall(payload)
            connection.shutdown(socket.SHUT_WR)
        finally:
            connection.close()
    except (OSError, ValueError):
        pass


def main():
    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            return

        event_name = first_string(
            payload,
            ("hook_event_name", "hookEventName", "event_name", "eventName", "event"),
        )
        if not event_name:
            return
        activity = activity_for(event_name, payload)
        if activity is None:
            return

        provider = provider_for(payload)
        session_id = first_string(
            payload,
            (
                "session_id",
                "sessionId",
                "thread_id",
                "threadId",
                "conversation_id",
                "conversationId",
            ),
        )
        if not session_id:
            return

        normalized = {
            "sessionID": session_id,
            "host": host_for(provider, payload),
            "activity": activity,
        }
        name = first_string(
            payload,
            ("session_name", "sessionName", "thread_name", "threadName", "title"),
        )
        if name:
            normalized["name"] = name
        send_event(normalized)
        # Codex Stop hooks parse successful stdout as a JSON hook result.
        if provider == "codex" and event_name.lower().replace("_", "") == "stop":
            sys.stdout.write("{}")
    except Exception:
        # Hooks must never alter or delay the provider workflow.
        pass


if __name__ == "__main__":
    main()
