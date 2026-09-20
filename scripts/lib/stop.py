#!/usr/bin/env python3
"""Identity-verified stop of this plugin's subscriber for one endpoint socket.

This is the only place a process is signaled outside the plugin's own reload action. It
verifies every identity signal before signaling (same UID, ``HERDR_PLUGIN_ID=agent-tree``,
the exact ``HERDR_SOCKET_PATH`` and ``HERDR_PLUGIN_STATE_DIR``, ``agent-tree subscriber``
argv, and an executable inside an explicitly named owned root or a ``.stage-old.*`` sibling),
refuses without signaling when any subscriber or the lock holder is unverifiable or foreign,
then waits for the process and its lock to disappear.

PID reuse is handled explicitly: a process identity (Linux ``/proc/<pid>/stat`` field 22,
``starttime``) is captured before the first signal, and every later signal re-checks that the
PID still owns that identity and still passes the subscriber checks. If the original exited
and the PID was reused, the original is treated as stopped and the replacement is never
signaled.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import signal
import sys
import time

SOCKET_ENV = "HERDR_SOCKET_PATH"
ID_ENV = "HERDR_PLUGIN_ID"
STATE_ENV = "HERDR_PLUGIN_STATE_DIR"
DELETED_SUFFIX = " (deleted)"


def norm_exe(path: str) -> str:
    return path[: -len(DELETED_SUFFIX)] if path.endswith(DELETED_SUFFIX) else path


def read_exe(pid: int) -> str | None:
    try:
        return norm_exe(os.readlink(f"/proc/{pid}/exe"))
    except OSError:
        return None


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


def proc_starttime(pid: int) -> int | None:
    """Linux process start time (``/proc/<pid>/stat`` field 22), stable for the process."""
    try:
        raw = open(f"/proc/{pid}/stat", "rb").read().decode("utf-8", "replace")
    except OSError:
        return None
    index = raw.rfind(")")
    if index < 0:
        return None
    fields = raw[index + 2 :].split()
    # fields[0] is state (field 3); starttime is field 22 -> fields[19].
    if len(fields) < 20:
        return None
    try:
        return int(fields[19])
    except ValueError:
        return None


def same_path(a: str, b: str) -> bool:
    if a == b:
        return True
    if not a or not b:
        return False
    try:
        return os.path.realpath(a) == os.path.realpath(b)
    except OSError:
        return False


def owned(exe: str, roots: list[str], prefix: str) -> bool:
    for root in roots:
        root = root.rstrip("/")
        if exe == root + "/src/agent-tree" or exe.startswith(root + "/"):
            return True
    if prefix:
        p = prefix.rstrip("/")
        if exe.startswith(p + "/.stage-old."):
            return True
    return False


def verify(pid: int, socket: str, state_dir: str, roots: list[str], prefix: str) -> list[str]:
    reasons = []
    try:
        if os.stat(f"/proc/{pid}").st_uid != os.geteuid():
            reasons.append("runs as a different uid")
    except OSError:
        reasons.append("its /proc ownership is unreadable")
    environ = read_environ(pid)
    if not environ:
        reasons.append("its /proc environ is unreadable or empty")
    if environ.get(ID_ENV) != "agent-tree":
        reasons.append("its HERDR_PLUGIN_ID is not agent-tree")
    if environ.get(SOCKET_ENV) != socket:
        reasons.append("its HERDR_SOCKET_PATH is not the endpoint socket")
    if not same_path(environ.get(STATE_ENV, ""), state_dir):
        reasons.append("its HERDR_PLUGIN_STATE_DIR is not the endpoint state dir")
    argv = read_cmdline(pid)
    if len(argv) < 2 or argv[1] != "subscriber":
        reasons.append("its argv is not an agent-tree subscriber")
    exe = read_exe(pid)
    if exe is None or os.path.basename(exe) != "agent-tree":
        reasons.append("its executable is not an agent-tree binary")
    elif not owned(exe, roots, prefix):
        reasons.append("its executable is outside the owned plugin roots")
    return reasons


def alive(pid: int) -> bool:
    return os.path.exists(f"/proc/{pid}")


def identity_holds(pid: int, starttime: int | None, socket: str, state_dir: str,
                   roots: list[str], prefix: str) -> bool:
    """True only while the live PID is the same process and still passes subscriber checks."""
    if starttime is None or not alive(pid):
        return False
    if proc_starttime(pid) != starttime:
        return False
    return not verify(pid, socket, state_dir, roots, prefix)


def find_subscribers(socket: str, state_dir: str, roots: list[str], prefix: str):
    verified = []
    foreign = []
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        pid = int(name)
        exe = read_exe(pid)
        if exe is None or os.path.basename(exe) != "agent-tree":
            continue
        argv = read_cmdline(pid)
        if len(argv) < 2 or argv[1] != "subscriber":
            continue
        if read_environ(pid).get(SOCKET_ENV) != socket:
            continue
        reasons = verify(pid, socket, state_dir, roots, prefix)
        starttime = proc_starttime(pid)
        if starttime is None:
            reasons.append("its process identity is unreadable")
        if reasons:
            foreign.append({"pid": pid, "exe": exe, "reasons": reasons})
        else:
            verified.append({"pid": pid, "starttime": starttime})
    return verified, foreign


def run_check_identity(args) -> int:
    pid = int(args.check_identity[0])
    starttime = int(args.check_identity[1])
    holds = identity_holds(pid, starttime, args.socket, args.state_dir, args.root, args.prefix)
    print(json.dumps({"identity_holds": holds, "starttime": proc_starttime(pid)}, sort_keys=True))
    return 0 if holds else 1


def run_stop(args) -> int:
    verified, foreign = find_subscribers(args.socket, args.state_dir, args.root, args.prefix)

    tag = hashlib.sha256(args.socket.encode("utf-8")).hexdigest()[:16]
    lock = os.path.join(args.state_dir, f"subscriber-{tag}.lock")
    lock_pid = None
    if os.path.exists(lock) and not foreign:
        try:
            lock_pid = json.load(open(lock, "r", encoding="utf-8")).get("pid")
        except (OSError, ValueError):
            lock_pid = None
        if isinstance(lock_pid, int) and alive(lock_pid):
            known = any(entry["pid"] == lock_pid for entry in verified)
            if not known or not identity_holds(lock_pid, next(
                    (e["starttime"] for e in verified if e["pid"] == lock_pid), None),
                    args.socket, args.state_dir, args.root, args.prefix):
                foreign.append({
                    "pid": lock_pid,
                    "exe": read_exe(lock_pid) or "",
                    "reasons": ["holds the subscriber lock without a matching verified identity"],
                })

    if foreign:
        print(json.dumps({
            "error": "refusing to stop an unverified or foreign subscriber",
            "foreign": foreign,
        }, sort_keys=True))
        return 3

    if args.dry_run:
        print(json.dumps({
            "dry_run": True,
            "subscribers": [{"pid": entry["pid"]} for entry in verified],
            "lock": lock,
            "lock_present": os.path.exists(lock),
        }, sort_keys=True))
        return 0

    # First signal: only to processes whose captured identity still holds.
    for entry in verified:
        if identity_holds(entry["pid"], entry["starttime"], args.socket, args.state_dir, args.root, args.prefix):
            try:
                os.kill(entry["pid"], signal.SIGTERM)
            except OSError:
                pass
    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline and any(
            identity_holds(e["pid"], e["starttime"], args.socket, args.state_dir, args.root, args.prefix)
            for e in verified):
        time.sleep(0.1)

    # Escalate only when the *same* process still owns the identity. A reused PID is left
    # alone: the original it replaced is already gone.
    for entry in verified:
        if alive(entry["pid"]) and identity_holds(
                entry["pid"], entry["starttime"], args.socket, args.state_dir, args.root, args.prefix):
            try:
                os.kill(entry["pid"], signal.SIGKILL)
            except OSError:
                pass
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline and any(
            identity_holds(e["pid"], e["starttime"], args.socket, args.state_dir, args.root, args.prefix)
            for e in verified):
        time.sleep(0.1)

    stopped = [e["pid"] for e in verified if not identity_holds(
        e["pid"], e["starttime"], args.socket, args.state_dir, args.root, args.prefix)]
    remaining = [e["pid"] for e in verified if identity_holds(
        e["pid"], e["starttime"], args.socket, args.state_dir, args.root, args.prefix)]

    lock_removed = False
    if os.path.exists(lock):
        stale = True
        try:
            lock_pid = json.load(open(lock, "r", encoding="utf-8")).get("pid")
        except (OSError, ValueError):
            lock_pid = None
        if isinstance(lock_pid, int) and alive(lock_pid):
            entry = next((e for e in verified if e["pid"] == lock_pid), None)
            if entry is not None and identity_holds(
                    lock_pid, entry["starttime"], args.socket, args.state_dir, args.root, args.prefix):
                stale = False
        if stale:
            try:
                os.remove(lock)
                lock_removed = True
            except OSError:
                pass

    result = {
        "stopped": stopped,
        "alive": remaining,
        "lock": lock,
        "lock_present": os.path.exists(lock),
        "lock_removed": lock_removed,
    }
    print(json.dumps(result, sort_keys=True))
    return 0 if not remaining and not result["lock_present"] else 4


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", default="")
    parser.add_argument("--state-dir", default="")
    parser.add_argument("--root", action="append", default=[])
    parser.add_argument("--prefix", default="")
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--check-identity", nargs=2, metavar=("PID", "STARTTIME"))
    parser.add_argument("--dry-run", action="store_true",
                        help="verify and report without signaling any process")
    args = parser.parse_args()

    if args.check_identity is not None:
        return run_check_identity(args)
    if not args.socket or not args.state_dir:
        parser.error("--socket and --state-dir are required unless --check-identity is used")
    return run_stop(args)


if __name__ == "__main__":
    sys.exit(main())
