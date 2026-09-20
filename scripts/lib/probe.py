#!/usr/bin/env python3
"""Read-only endpoint probe: staged binary hash and live subscriber state.

This performs no writes and never signals a process. It is safe to run against a local
endpoint or to pipe over SSH to a remote endpoint (``ssh target python3 - --socket S ...``).
Subscribers are scoped by the endpoint's own ``HERDR_SOCKET_PATH`` so two servers that share
a host never count each other's ``agent-tree subscriber`` process.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

AGENT_TREE = "agent-tree"
SOCKET_ENV = "HERDR_SOCKET_PATH"
DELETED_SUFFIX = " (deleted)"


def sha256_file(path: str) -> str | None:
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(65536), b""):
                digest.update(chunk)
    except OSError:
        return None
    return digest.hexdigest()


def server_tag(socket: str) -> str:
    return hashlib.sha256(socket.encode("utf-8")).hexdigest()[:16]


def read_cmdline(pid: int) -> list[str]:
    try:
        raw = open(f"/proc/{pid}/cmdline", "rb").read()
    except OSError:
        return []
    return [part.decode("utf-8", "replace") for part in raw.split(b"\0") if part]


def read_environ(pid: int) -> dict[str, str]:
    try:
        raw = open(f"/proc/{pid}/environ", "rb").read()
    except OSError:
        return {}
    values = {}
    for entry in raw.split(b"\0"):
        if b"=" in entry:
            key, value = entry.split(b"=", 1)
            values[key.decode("utf-8", "replace")] = value.decode("utf-8", "replace")
    return values


def read_exe(pid: int) -> str | None:
    try:
        exe = os.readlink(f"/proc/{pid}/exe")
    except OSError:
        return None
    if exe.endswith(DELETED_SUFFIX):
        exe = exe[: -len(DELETED_SUFFIX)]
    return exe


def pids() -> list[int]:
    result = []
    for name in os.listdir("/proc"):
        if name.isdigit():
            result.append(int(name))
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--stage", default="")
    parser.add_argument("--prefix", default="")
    parser.add_argument("--state-dir", default="")
    args = parser.parse_args()

    prefix = args.prefix
    if not prefix and args.stage:
        prefix = os.path.dirname(os.path.dirname(os.path.abspath(args.stage)))

    stage = os.path.abspath(args.stage) if args.stage else ""
    replaced_prefix = prefix.rstrip("/") + "/.stage-old." if prefix else ""

    subscribers = []
    stale = []
    for pid in pids():
        exe = read_exe(pid)
        if exe is None or os.path.basename(exe) != AGENT_TREE:
            continue
        argv = read_cmdline(pid)
        if len(argv) < 2 or argv[1] != "subscriber":
            continue
        socket = read_environ(pid).get(SOCKET_ENV, "")
        under_replaced = bool(replaced_prefix) and exe.startswith(replaced_prefix)
        entry = {
            "pid": pid,
            "exe": exe,
            "sha256": sha256_file(f"/proc/{pid}/exe") or "",
            "socket": socket,
            "replaced_stage": under_replaced,
        }
        if under_replaced:
            stale.append(entry)
            continue
        if socket == args.socket:
            subscribers.append(entry)

    result = {
        "socket": args.socket,
        "stage": {
            "path": stage,
            "present": bool(stage) and os.path.exists(stage),
            "sha256": sha256_file(stage) if stage else None,
        },
        "subscribers": subscribers,
        "subscriber_count": len(subscribers),
        "replaced_stage_subscribers": stale,
    }

    if args.state_dir:
        tag = server_tag(args.socket)
        lock = os.path.join(args.state_dir, f"subscriber-{tag}.lock")
        lock_info = {"path": lock, "present": os.path.exists(lock), "pid": None, "alive": None}
        if lock_info["present"]:
            try:
                with open(lock, "r", encoding="utf-8") as handle:
                    lock_info["pid"] = json.load(handle).get("pid")
            except (OSError, ValueError):
                lock_info["pid"] = None
            if isinstance(lock_info["pid"], int):
                lock_info["alive"] = os.path.exists(f"/proc/{lock_info['pid']}")
        result["lock"] = lock_info
        result["tree_off"] = os.path.exists(os.path.join(args.state_dir, f"tree-off-{tag}.flag"))
    else:
        result["lock"] = None
        result["tree_off"] = None

    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
